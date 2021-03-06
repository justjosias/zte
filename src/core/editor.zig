const std = @import("std");

const core = @import("../core.zig");

const debug = std.debug;
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const os = std.os;

pub const History = core.List(core.Text);

pub const File = struct {
    path: []const u8,
    stat: ?os.Stat,
};

pub const Editor = struct {
    allocator: *mem.Allocator,
    history: History,
    history_pos: usize = 0,
    on_disk_pos: usize = 0,
    copy_pos: usize = 0,
    file: ?File = null,

    pub fn fromString(allocator: *mem.Allocator, str: []const u8) !Editor {
        var res = Editor{
            .allocator = allocator,
            .history = History{ .allocator = allocator },
        };
        const t = try core.Text.fromString(allocator, str);
        res.history = try res.history.append(t);
        return res;
    }

    pub fn fromFile(allocator: *mem.Allocator, path: []const u8) !Editor {
        const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var res = try fromString(allocator, "");
                res.file = File{
                    .path = path,
                    .stat = null,
                };

                return res;
            },
            else => |err2| return err2,
        };
        defer file.close();

        const stat = try os.fstat(file.handle);
        var res = if (stat.size == 0)
            try Editor.fromString(allocator, "")
        else blk: {
            const content = try os.mmap(null, @intCast(usize, stat.size), os.PROT_READ, os.MAP_PRIVATE, file.handle, 0);
            defer os.munmap(content);
            break :blk try Editor.fromString(allocator, content);
        };
        res.file = File{
            .path = path,
            .stat = stat,
        };

        return res;
    }

    pub fn save(editor: Editor) !Editor {
        if (!editor.dirty())
            return editor;

        const editor_file = editor.file orelse return error.NoFile;
        const file = try fs.cwd().openFile(editor_file.path, .{ .write = true });
        defer file.close();

        const curr = editor.current();
        const out_stream = file.outStream();
        var buf_out_stream = io.bufferedOutStream(out_stream);
        const Stream = @TypeOf(buf_out_stream.outStream());
        try curr.content.foreach(0, buf_out_stream.outStream(), struct {
            fn each(stream: Stream, i: usize, item: u8) !void {
                try stream.writeByte(item);
            }
        }.each);
        try buf_out_stream.flush();

        var res = editor;
        res.on_disk_pos = res.history_pos;
        return res;
    }

    pub fn addUndo(editor: Editor, t: core.Text) !Editor {
        if (t.equal(editor.current()))
            return editor;

        var res = editor;
        debug.assert(res.history_pos < res.history.len());
        res.history_pos = res.history.len();
        res.history = try res.history.append(t);
        return res;
    }

    pub fn current(editor: Editor) core.Text {
        return editor.history.at(editor.history_pos);
    }

    pub fn onDisk(editor: Editor) core.Text {
        return editor.history.at(editor.on_disk_pos);
    }

    pub fn copied(editor: Editor) core.Text {
        return editor.history.at(editor.copy_pos);
    }

    pub fn undo(editor: Editor) !Editor {
        const curr = editor.current();
        var res = editor;
        while (res.history_pos != 0) {
            res.history_pos -= 1;
            const prev = res.current();
            if (!curr.content.equal(prev.content))
                break;
        }

        res.history = try res.history.append(res.current());
        return res;
    }

    pub fn dirty(editor: Editor) bool {
        return !core.Text.Content.equal(editor.onDisk().content, editor.current().content);
    }

    pub fn copy(editor: Editor) Editor {
        var res = editor;
        res.copy_pos = res.history_pos;
        return res;
    }

    pub fn copyClipboard(editor: Editor) !void {
        const allocator = editor.allocator;
        const text = editor.current();
        const proc = try core.clipboard.copy(allocator);
        errdefer _ = proc.kill() catch undefined;

        var file_out = proc.stdin.?.outStream();
        var buf_out = io.bufferedOutStream(file_out);
        const Stream = @TypeOf(buf_out.outStream());
        const Context = struct {
            stream: Stream,
            text: core.Text,
            end: usize = 0,
        };

        try text.cursors.foreach(
            0,
            Context{
                .stream = buf_out.outStream(),
                .text = text,
            },
            struct {
                fn each(c: Context, i: usize, cursor: core.Cursor) !void {
                    if (i != 0)
                        try c.stream.writeAll("\n");

                    var new_c = c;
                    new_c.end = cursor.end().index;
                    c.text.content.foreach(
                        cursor.start().index,
                        new_c,
                        struct {
                            fn each2(context: Context, j: usize, char: u8) !void {
                                if (j == context.end)
                                    return error.Break;

                                try context.stream.writeAll(&[_]u8{char});
                            }
                        }.each2,
                    ) catch |err| switch (err) {
                        error.Break => {},
                        else => |err2| return err2,
                    };
                }
            }.each,
        );

        try buf_out.flush();
        proc.stdin.?.close();
        proc.stdin = null;
        const term = try proc.wait();
    }

    pub fn pasteClipboard(editor: Editor) !Editor {
        const allocator = editor.allocator;
        var res = editor;
        var text = res.current();
        const proc = try core.clipboard.paste(allocator);
        errdefer _ = proc.kill() catch undefined;

        var file_out = proc.stdout.?.inStream();
        const str = try file_out.readAllAlloc(allocator, 1024 * 1024 * 512);
        switch (try proc.wait()) {
            .Exited => |status| {
                if (status != 0)
                    return error.CopyFailed;
            },
            else => return error.CopyFailed,
        }

        text = try text.paste(str);
        res = try res.addUndo(text);
        return res;
    }
};
