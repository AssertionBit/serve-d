module served.lsp.textdocumentmanager;

import std.algorithm;
import std.experimental.logger;
import std.json;
import std.string;
import std.utf : codeLength, decode, UseReplacementDchar;

import served.lsp.jsonrpc;
import served.lsp.protocol;

import painlessjson;

struct Document
{
	DocumentUri uri;
	string languageId;
	long version_;
	private char[] text;

	this(DocumentUri uri)
	{
		this.uri = uri;
		languageId = "d";
		version_ = 0;
		text = null;
	}

	this(TextDocumentItem doc)
	{
		uri = doc.uri;
		languageId = doc.languageId;
		version_ = doc.version_;
		text = doc.text.dup;
	}

	static Document nullDocument(scope const(char)[] content)
	{
		Document ret;
		ret.setContent(content);
		return ret;
	}

	version (unittest) private static Document nullDocumentOwnMemory(char[] content)
	{
		Document ret;
		ret.text = content;
		return ret;
	}

	const(char)[] rawText()
	{
		return cast(const(char)[]) text;
	}

	size_t length() const @property
	{
		return text.length;
	}

	void setContent(scope const(char)[] newContent)
	{
		if (newContent.length <= text.length)
		{
			text[0 .. newContent.length] = newContent;
			text.length = newContent.length;
		}
		else
		{
			text = text.assumeSafeAppend;
			text.length = newContent.length;
			text = text.assumeSafeAppend;
			text[0 .. $] = newContent;
		}
	}

	void applyChange(TextRange range, scope const(char)[] newContent)
	{
		auto start = positionToBytes(range[0]);
		auto end = positionToBytes(range[1]);

		if (start > end)
			swap(start, end);

		if (start == 0 && end == text.length)
		{
			setContent(newContent);
			return;
		}

		auto addition = newContent.representation;
		int removed = cast(int) end - cast(int) start;
		int added = cast(int) addition.length - removed;
		text = text.assumeSafeAppend;
		if (added > 0)
		{
			text.length += added;
			// text[end + added .. $] = text[end .. $ - added];
			for (int i = cast(int) text.length - 1; i >= end + added; i--)
				text[i] = text[i - added];
		}
		else if (added < 0)
		{
			for (size_t i = start; i < text.length + added; i++)
				text[i] = text[i - added];

			text = text[0 .. $ + added];
		}
		text = text.assumeSafeAppend;

		foreach (i, c; addition)
			text[start + i] = cast(char) c;
	}

	size_t offsetToBytes(size_t offset)
	{
		return .countBytesUntilUTF16Index(text, offset);
	}

	size_t bytesToOffset(size_t bytes)
	{
		return .countUTF16Length(text[0 .. min($, bytes)]);
	}

	size_t positionToOffset(Position position)
	{
		size_t offset = 0;
		size_t bytes = 0;
		while (bytes < text.length && position.line > 0)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
				position.line--;
			utf16DecodeUtf8Length(c, offset, bytes);
		}

		while (bytes < text.length && position.character > 0)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
				break;
			size_t utf16Size;
			utf16DecodeUtf8Length(c, utf16Size, bytes);
			if (utf16Size < position.character)
				position.character -= utf16Size;
			else
				position.character = 0;
			offset += utf16Size;
		}
		return offset;
	}

	size_t positionToBytes(Position position)
	{
		size_t index = 0;
		while (index < text.length && position.line > 0)
			if (text.ptr[index++] == '\n')
				position.line--;

		while (index < text.length && position.character > 0)
		{
			const c = text.ptr[index];
			if (c == '\n')
				break;
			size_t utf16Size;
			utf16DecodeUtf8Length(c, utf16Size, index);
			if (utf16Size < position.character)
				position.character -= utf16Size;
			else
				position.character = 0;
		}
		return index;
	}

	Position offsetToPosition(size_t offset)
	{
		size_t bytes;
		size_t index;
		size_t lastNl = -1;

		Position ret;
		while (bytes < text.length && index < offset)
		{
			const c = text.ptr[bytes];
			if (c == '\n')
			{
				ret.line++;
				lastNl = index;
			}
			utf16DecodeUtf8Length(c, index, bytes);
		}
		const start = lastNl + 1;
		ret.character = cast(uint)(index - start);
		return ret;
	}

	Position bytesToPosition(size_t bytes)
	{
		if (bytes > text.length)
			bytes = text.length;
		auto part = text.ptr[0 .. bytes].representation;
		size_t lastNl = -1;
		Position ret;
		foreach (i; 0 .. bytes)
		{
			if (part.ptr[i] == '\n')
			{
				ret.line++;
				lastNl = i;
			}
		}
		ret.character = cast(uint)(cast(const(char)[]) part[lastNl + 1 .. $]).countUTF16Length;
		return ret;
	}

	/// Returns an the position at "end" starting from the given "src" position which is assumed to be at byte "start"
	/// Faster to quickly calculate nearby positions of known byte positions.
	/// Falls back to $(LREF bytesToPosition) if end is before start.
	Position movePositionBytes(Position src, size_t start, size_t end)
	{
		if (end == start)
			return src;
		if (end < start)
			return bytesToPosition(end);

		auto t = text[start .. end];
		size_t bytes;
		while (bytes < t.length)
		{
			const c = t.ptr[bytes];
			if (c == '\n')
			{
				src.line++;
				src.character = 0;
				bytes++;
			}
			else
				utf16DecodeUtf8Length(c, src.character, bytes);
		}
		return src;
	}

	TextRange wordRangeAt(Position position)
	{
		auto chars = wordInLine(lineAtScope(position), position.character);
		return TextRange(Position(position.line, chars[0]), Position(position.line, chars[1]));
	}

	size_t[2] lineByteRangeAt(uint line)
	{
		size_t start = 0;
		size_t index = 0;
		while (line > 0 && index < text.length)
		{
			const c = text.ptr[index++];
			if (c == '\n')
			{
				line--;
				if (line == 0)
					return [start, index];
				else
					start = index;
			}
		}
		// if !found
		if (line != 0)
			return [0, 0];
		return [start, text.length];
	}

	/// Returns the text of a line at the given position.
	string lineAt(Position position)
	{
		return lineAt(position.line);
	}

	/// Returns the text of a line starting at line 0.
	string lineAt(uint line)
	{
		return lineAtScope(line).idup;
	}

	/// Returns the line text which is only in this scope if text isn't modified
	/// See_Also: $(LREF lineAt)
	scope const(char)[] lineAtScope(Position position)
	{
		return lineAtScope(position.line);
	}

	/// Returns the line text which is only in this scope if text isn't modified
	/// See_Also: $(LREF lineAt)
	scope const(char)[] lineAtScope(uint line)
	{
		auto range = lineByteRangeAt(line);
		return text[range[0] .. range[1]];
	}

	unittest
	{
		void assertEqual(A, B)(A a, B b)
		{
			import std.conv : to;

			assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
		}

		Document doc;
		doc.setContent(`abc
hellö world
how åre
you?`);
		assertEqual(doc.lineAt(Position(0, 0)), "abc\n");
		assertEqual(doc.lineAt(Position(0, 100)), "abc\n");
		assertEqual(doc.lineAt(Position(1, 3)), "hellö world\n");
		assertEqual(doc.lineAt(Position(2, 0)), "how åre\n");
		assertEqual(doc.lineAt(Position(3, 0)), "you?");
		assertEqual(doc.lineAt(Position(3, 8)), "you?");
		assertEqual(doc.lineAt(Position(4, 0)), "");
	}

	EolType eolAt(int line)
	{
		size_t index = 0;
		int curLine = 0;
		bool prevWasCr = false;
		while (index < text.length)
		{
			if (curLine > line)
				return EolType.lf;
			auto c = decode!(UseReplacementDchar.yes)(text, index);
			if (c == '\n')
			{
				if (curLine == line)
				{
					return prevWasCr ? EolType.crlf : EolType.lf;
				}
				curLine++;
			}
			prevWasCr = c == '\r';
		}
		return EolType.lf;
	}
}

struct TextDocumentManager
{
	Document[] documentStore;

	ref Document opIndex(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			throw new Exception("Document '" ~ uri ~ "' not found");
		return documentStore[idx];
	}

	Document tryGet(string uri)
	{
		auto idx = documentStore.countUntil!(a => a.uri == uri);
		if (idx == -1)
			return Document.init;
		return documentStore[idx];
	}

	static TextDocumentSyncKind syncKind()
	{
		return TextDocumentSyncKind.incremental;
	}

	bool process(RequestMessage msg)
	{
		if (msg.method == "textDocument/didOpen")
		{
			auto params = msg.params.fromJSON!DidOpenTextDocumentParams;
			documentStore ~= Document(params.textDocument);
			return true;
		}
		else if (msg.method == "textDocument/didClose")
		{
			auto targetUri = msg.params["textDocument"]["uri"].str;
			auto idx = documentStore.countUntil!(a => a.uri == targetUri);
			if (idx >= 0)
			{
				documentStore[idx] = documentStore[$ - 1];
				documentStore.length--;
			}
			else
			{
				warning("Received didClose notification for URI not in system: ", targetUri);
				warning(
						"This can be a potential memory leak if it was previously opened under a different name.");
			}
			return true;
		}
		else if (msg.method == "textDocument/didChange")
		{
			auto targetUri = msg.params["textDocument"]["uri"].str;
			auto idx = documentStore.countUntil!(a => a.uri == targetUri);
			if (idx >= 0)
			{
				documentStore[idx].version_ = msg.params["textDocument"]["version"].integer;
				foreach (change; msg.params["contentChanges"].array)
				{
					if (auto rangePtr = "range" in change)
					{
						auto range = *rangePtr;
						TextRange textRange = cast(Position[2])[
							range["start"].fromJSON!Position, range["end"].fromJSON!Position
						];
						documentStore[idx].applyChange(textRange, change["text"].str);
					}
					else
						documentStore[idx].setContent(change["text"].str);
				}
			}
			return true;
		}
		return false;
	}
}

struct PerDocumentCache(T)
{
	struct Entry
	{
		Document document;
		T data;
	}

	Entry[] entries;

	T cached(ref TextDocumentManager source, string uri)
	{
		auto newest = source.tryGet(uri);
		foreach (entry; entries)
			if (entry.document.uri == uri)
			{
				if (entry.document.version_ >= newest.version_)
					return entry.data;
				else
					return T.init;
			}
		return T.init;
	}

	void store(Document document, T data)
	{
		foreach (ref entry; entries)
		{
			if (entry.document.uri == document.uri)
			{
				if (document.version_ >= entry.document.version_)
				{
					entry.document = document;
					entry.data = data;
				}
				return;
			}
		}
		entries ~= Entry(document, data);
	}
}

/// Returns a range of the identifier/word at the given position.
uint[2] wordInLine(const(char)[] line, uint character)
{
	size_t index = 0;
	uint offs = 0;

	uint lastStart = character;
	uint start = character, end = character + 1;
	bool searchStart = true;

	while (index < line.length)
	{
		const c = decode(line, index);
		const l = cast(uint) c.codeLength!wchar;

		if (searchStart)
		{
			if (isIdentifierSeparatingChar(c))
				lastStart = offs + l;

			if (offs + l >= character)
			{
				start = lastStart;
				searchStart = false;
			}

			offs += l;
		}
		else
		{
			end = offs;
			offs += l;
			if (isIdentifierSeparatingChar(c))
				break;
		}
	}
	return [start, end];
}

bool isIdentifierSeparatingChar(dchar c)
{
	return c < 48 || (c > 57 && c < 65) || c == '[' || c == '\\' || c == ']'
		|| c == '`' || (c > 122 && c < 128) || c == '\u2028' || c == '\u2029'; // line separators
}

unittest
{
	Document doc;
	doc.text.reserve(16);
	auto ptr = doc.text.ptr;
	assert(doc.rawText.length == 0);
	doc.setContent("Hello world");
	assert(doc.rawText == "Hello world");
	doc.setContent("foo");
	assert(doc.rawText == "foo");
	doc.setContent("foo bar baz baf");
	assert(doc.rawText == "foo bar baz baf");
	doc.applyChange(TextRange(0, 4, 0, 8), "");
	assert(doc.rawText == "foo baz baf");
	doc.applyChange(TextRange(0, 4, 0, 8), "bad");
	assert(doc.rawText == "foo badbaf");
	doc.applyChange(TextRange(0, 4, 0, 8), "bath");
	assert(doc.rawText == "foo bathaf");
	doc.applyChange(TextRange(0, 4, 0, 10), "bath");
	assert(doc.rawText == "foo bath");
	doc.applyChange(TextRange(0, 0, 0, 8), "bath");
	assert(doc.rawText == "bath");
	doc.applyChange(TextRange(0, 0, 0, 1), "par");
	assert(doc.rawText == "parath", doc.rawText);
	doc.applyChange(TextRange(0, 0, 0, 4), "");
	assert(doc.rawText == "th");
	doc.applyChange(TextRange(0, 2, 0, 2), "e");
	assert(doc.rawText == "the");
	doc.applyChange(TextRange(0, 0, 0, 0), "in");
	assert(doc.rawText == "inthe");
	assert(ptr is doc.text.ptr);
}

pragma(inline, true) private void utf16DecodeUtf8Length(A, B)(char c, ref A utf16Index,
		ref B utf8Index) @safe nothrow @nogc
{
	switch (c & 0b1111_0000)
	{
	case 0b1110_0000:
		// assume valid encoding (no wrong surrogates)
		utf16Index++;
		utf8Index += 3;
		break;
	case 0b1111_0000:
		utf16Index += 2;
		utf8Index += 4;
		break;
	case 0b1100_0000:
	case 0b1101_0000:
		utf16Index++;
		utf8Index += 2;
		break;
	default:
		utf16Index++;
		utf8Index++;
		break;
	}
}

pragma(inline, true) size_t countUTF16Length(scope const(char)[] text) @safe nothrow @nogc
{
	size_t offset;
	size_t index;
	while (index < text.length)
		utf16DecodeUtf8Length((() @trusted => text.ptr[index])(), offset, index);
	return offset;
}

pragma(inline, true) size_t countBytesUntilUTF16Index(scope const(char)[] text, size_t utf16Offset) @safe nothrow @nogc
{
	size_t bytes;
	size_t offset;
	while (offset < utf16Offset && bytes < text.length)
		utf16DecodeUtf8Length((() @trusted => text.ptr[bytes])(), offset, bytes);
	return bytes;
}

version (unittest)
{
	import core.time;

	Document testUnicodeDocument = Document.nullDocumentOwnMemory(cast(char[]) `///
/// Copyright © 2020 Somebody (not actually™) x3
///
module some.file;

enum Food : int
{
	pizza = '\U0001F355', // 🍕
	burger = '\U0001F354', // 🍔
	chicken = '\U0001F357', // 🍗
	taco = '\U0001F32E', // 🌮
	wrap = '\U0001F32F', // 🌯
	salad = '\U0001F957', // 🥗
	pasta = '\U0001F35D', // 🍝
	sushi = '\U0001F363', // 🍣
	oden = '\U0001F362', // 🍢
	egg = '\U0001F373', // 🍳
	croissant = '\U0001F950', // 🥐
	baguette = '\U0001F956', // 🥖
	popcorn = '\U0001F37F', // 🍿
	coffee = '\u2615', // ☕
	cookie = '\U0001F36A', // 🍪
}

void main() {
	// taken from https://github.com/DlangRen/Programming-in-D/blob/master/ddili/src/ders/d.cn/aa.d
	int[string] colorCodes = [ /* ... */ ];

	if ("purple" in colorCodes) {
		// ü®™🍳键 “purple” 在表中

	} else { // line 31
		//表中不存在 键 “purple” 
	}

	string x;
}`);

	enum testSOF_byte = 0;
	enum testSOF_offset = 0;
	enum testSOF_position = Position(0, 0);

	enum testEOF_byte = 872;
	enum testEOF_offset = 805;
	enum testEOF_position = Position(36, 1);

	// in line before unicode
	enum testLinePreUni_byte = 757;
	enum testLinePreUni_offset = 724;
	enum testLinePreUni_position = Position(29, 4); // after `//`

	// in line after unicode
	enum testLinePostUni_byte = 789;
	enum testLinePostUni_offset = 742;
	enum testLinePostUni_position = Position(29, 22); // after `purple” 在`

	// ascii line after unicode line
	enum testMidAsciiLine_byte = 804;
	enum testMidAsciiLine_offset = 753;
	enum testMidAsciiLine_position = Position(31, 7);

	@("{offset, bytes, position} -> {offset, bytes, position}")
	unittest
	{
		import std.conv;
		import std.stdio;

		static foreach (test; [
				"SOF", "EOF", "LinePreUni", "LinePostUni", "MidAsciiLine"
			])
		{
			{
				enum testOffset = mixin("test" ~ test ~ "_offset");
				enum testByte = mixin("test" ~ test ~ "_byte");
				enum testPosition = mixin("test" ~ test ~ "_position");

				writeln(" === Test ", test, " ===");

				writeln(testByte, " byte -> offset ", testOffset);
				assert(testUnicodeDocument.bytesToOffset(testByte) == testOffset,
						"fail " ~ test ~ " byte->offset = " ~ testUnicodeDocument.bytesToOffset(testByte)
						.to!string);
				writeln(testByte, " byte -> position ", testPosition);
				assert(testUnicodeDocument.bytesToPosition(testByte) == testPosition,
						"fail " ~ test ~ " byte->position = " ~ testUnicodeDocument.bytesToPosition(testByte)
						.to!string);

				writeln(testOffset, " offset -> byte ", testByte);
				assert(testUnicodeDocument.offsetToBytes(testOffset) == testByte,
						"fail " ~ test ~ " offset->byte = " ~ testUnicodeDocument.offsetToBytes(testOffset)
						.to!string);
				writeln(testOffset, " offset -> position ", testPosition);
				assert(testUnicodeDocument.offsetToPosition(testOffset) == testPosition,
						"fail " ~ test ~ " offset->position = " ~ testUnicodeDocument.offsetToPosition(testOffset)
						.to!string);

				writeln(testPosition, " position -> offset ", testOffset);
				assert(testUnicodeDocument.positionToOffset(testPosition) == testOffset,
						"fail " ~ test ~ " position->offset = " ~ testUnicodeDocument.positionToOffset(testPosition)
						.to!string);
				writeln(testPosition, " position -> byte ", testByte);
				assert(testUnicodeDocument.positionToBytes(testPosition) == testByte,
						"fail " ~ test ~ " position->byte = " ~ testUnicodeDocument.positionToBytes(testPosition)
						.to!string);

				writeln();
			}
		}

		const size_t maxBytes = testEOF_byte;
		const size_t maxOffset = testEOF_offset;
		const Position maxPosition = testEOF_position;

		writeln("max offset -> byte");
		assert(testUnicodeDocument.offsetToBytes(size_t.max) == maxBytes);
		writeln("max offset -> position");
		assert(testUnicodeDocument.offsetToPosition(size_t.max) == maxPosition);
		writeln("max byte -> offset");
		assert(testUnicodeDocument.bytesToOffset(size_t.max) == maxOffset);
		writeln("max byte -> position");
		assert(testUnicodeDocument.bytesToPosition(size_t.max) == maxPosition);
		writeln("max position -> offset");
		assert(testUnicodeDocument.positionToOffset(Position(uint.max, uint.max)) == maxOffset);
		writeln("max position -> byte");
		assert(testUnicodeDocument.positionToBytes(Position(uint.max, uint.max)) == maxBytes);
	}

	@("character transform benchmarks")
	unittest
	{
		import std.datetime.stopwatch;
		import std.random;
		import std.stdio;

		enum PositionCount = 32;
		size_t[PositionCount] testBytes;
		size_t[PositionCount] testOffsets;
		Position[PositionCount] testPositions;

		static immutable funs = [
			"offsetToBytes", "offsetToPosition", "bytesToOffset", "bytesToPosition",
			"positionToOffset", "positionToBytes"
		];

		size_t debugSum;

		size_t lengthUtf16 = testUnicodeDocument.text.codeLength!wchar;
		enum TestRepeats = 10;
		Duration[TestRepeats][funs.length] times;

		StopWatch sw;
		static foreach (iterations; [
				1e3, 1e4, /* 1e5 */
			])
		{
			writeln("==================");
			writeln("Timing ", iterations, "x", PositionCount, "x", TestRepeats, " iterations:");
			foreach (ref row; times)
				foreach (ref col; row)
					col = Duration.zero;

			static foreach (t; 0 .. TestRepeats)
			{
				foreach (i, ref v; testOffsets)
				{
					v = uniform(0, lengthUtf16);
					testBytes[i] = testUnicodeDocument.offsetToBytes(v);
					testPositions[i] = testUnicodeDocument.offsetToPosition(v);
				}
				static foreach (fi, fun; funs)
				{
					sw.reset();
					sw.start();
					foreach (i; 0 .. iterations)
					{
						foreach (v; 0 .. PositionCount)
						{
							static if (fun[0] == 'b')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testBytes[v]).sumVal;");
							else static if (fun[0] == 'o')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testOffsets[v]).sumVal;");
							else static if (fun[0] == 'p')
								mixin("debugSum |= testUnicodeDocument." ~ fun ~ "(testPositions[v]).sumVal;");
							else
								static assert(false);
						}
					}
					sw.stop();
					times[fi][t] = sw.peek;
				}
			}
			static foreach (fi, fun; funs)
			{
				writeln(fun, ": ", formatDurationDistribution(times[fi]));
			}
			writeln();
			writeln();
		}

		writeln("tricking the optimizer", debugSum);
	}

	private pragma(inline, true) size_t sumVal(size_t v) pure @safe nothrow @nogc
	{
		return v;
	}

	private pragma(inline, true) size_t sumVal(Position v) pure @trusted nothrow @nogc
	{
		return cast(size_t)*(cast(ulong*)&v);
	}

	private string formatDurationDistribution(size_t n)(Duration[n] durs)
	{
		import std.algorithm : fold, map, sort, sum;
		import std.format : format;
		import std.math : sqrt;

		Duration total = durs[].fold!"a+b";
		sort!"a<b"(durs[]);
		double msAvg = cast(double) total.total!"hnsecs" / 10_000.0 / n;
		double msMedian = cast(double) durs[$ / 2].total!"hnsecs" / 10_000.0;
		double[n] diffs = 0;
		foreach (i, dur; durs)
			diffs[i] = (cast(double) dur.total!"hnsecs" / 10_000.0) - msAvg;
		double msStdDeviation = diffs[].map!"a*a".sum.sqrt;
		return format!"[avg=%.4fms, median=%.4f, sd=%.4f]"(msAvg, msMedian, msStdDeviation);
	}
}
