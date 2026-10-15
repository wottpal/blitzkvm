// BlitzKVM's clipboard bridge on the remote Mac. The app starts it over SSH
// for each session and nothing stays installed: osascript runs it twice,
// "watch" writes the pasteboard's changes to stdout and "apply" puts what
// arrives on stdin on the pasteboard, one JSON line per message.
ObjC.import('AppKit');

// MARKER tags what this script put on the pasteboard, so "watch" doesn't
// send it back.
const MARKER = 'com.blitzkvm.synced';
const MAX_BYTES = 8 * 1024 * 1024;
// In order of importance: what doesn't fit in MAX_BYTES is left out from
// the end.
const TYPES = ['public.utf8-plain-text', 'public.rtf', 'public.html', 'public.url', 'public.png', 'public.tiff'];
// Password managers mark secrets and one-off data so that clipboard tools
// leave them alone (nspasteboard.org).
const SKIP = ['org.nspasteboard.ConcealedType', 'org.nspasteboard.TransientType', MARKER];

function run(argv) {
	if (argv[0] === 'watch') watch();
	else if (argv[0] === 'apply') apply();
}

function watch() {
	const pasteboard = $.NSPasteboard.generalPasteboard;
	const out = $.NSFileHandle.fileHandleWithStandardOutput;
	const emit = (message) =>
		out.writeData($(JSON.stringify(message) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
	emit({ t: 'hello', v: 1 });
	let last = Number(pasteboard.changeCount);
	let idle = 0;
	for (;;) {
		delay(0.25);
		const count = Number(pasteboard.changeCount);
		if (count !== last) {
			last = count;
			const items = read(pasteboard);
			if (items) {
				emit({ t: 'clip', items: items });
				idle = 0;
				continue;
			}
		}
		// A ping every 10 s: once the session is gone, the write fails and
		// this process ends.
		if (++idle >= 40) {
			emit({ t: 'ping' });
			idle = 0;
		}
	}
}

function read(pasteboard) {
	const items = pasteboard.pasteboardItems;
	if (!items || items.isNil() || Number(items.count) === 0) return null;
	const item = items.objectAtIndex(0);
	const types = ObjC.deepUnwrap(item.types) || [];
	if (types.some((type) => SKIP.includes(type))) return null;
	const out = {};
	let size = 0;
	for (const type of TYPES) {
		if (!types.includes(type)) continue;
		if (type === 'public.tiff' && 'public.png' in out) continue; // the same image, larger
		const data = item.dataForType(type);
		if (!data || data.isNil()) continue;
		const length = Number(data.length);
		if (size + length > MAX_BYTES) continue;
		size += length;
		out[type] = data.base64EncodedStringWithOptions(0).js;
	}
	return Object.keys(out).length > 0 ? out : null;
}

function apply() {
	const pasteboard = $.NSPasteboard.generalPasteboard;
	const input = $.NSFileHandle.fileHandleWithStandardInput;
	let buffered = '';
	for (;;) {
		const data = input.availableData;
		if (Number(data.length) === 0) return; // the session ended
		// Messages are ASCII (base64 inside JSON), so a chunk never splits a
		// character.
		let from = buffered.length;
		buffered += $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
		let newline;
		while ((newline = buffered.indexOf('\n', from)) >= 0) {
			const line = buffered.slice(0, newline);
			buffered = buffered.slice(newline + 1);
			from = 0;
			if (line) write(pasteboard, JSON.parse(line));
		}
	}
}

function write(pasteboard, message) {
	if (message.t !== 'clip') return;
	const item = $.NSPasteboardItem.alloc.init;
	for (const type of Object.keys(message.items)) {
		const data = $.NSData.alloc.initWithBase64EncodedStringOptions(message.items[type], 0);
		if (!data.isNil()) item.setDataForType(data, type);
	}
	item.setStringForType('', MARKER);
	pasteboard.clearContents;
	pasteboard.writeObjects($([item]));
}
