//! Continuous Fuzzing Orchestrator.
//!
//! We have a number of machines which run
//!
//!     git clone https://github.com/tigerbeetle/tigerbeetle && cd tigerbeetle
//!     while True:
//!         git fetch origin && git reset --hard origin/main
//!         ./scripts/install_zig.sh
//!         ./zig/zig build scripts -- cfo
//!
//! By modifying this script, we can make those machines do interesting things.
//!
//! The primary use-case is fuzzing: `cfo` runs a random fuzzer, and, if it finds a failure, it is
//! recorded in devhubdb.
//!
//! Specifically:
//!
//! CFO keeps `args.concurrency` fuzzes running at the same time. For simplicity, it polls currently
//! running fuzzers for completion every second in a fuzzing loop. A fuzzer fails if it returns
//! non-zero error code.
//!
//! The fuzzing loops runs for `args.budget_minutes`. To detect hangs, if any fuzzer is still
//! running after additional `args.hang_minutes`, it is killed (thus returning non-zero status and
//! recording a failure).
//!
//! It is important that the caller (systemd typically) arranges for CFO to be a process group
//! leader. It is not possible to reliably wait for (grand) children with POSIX, so its on the
//! call-site to cleanup any run-away subprocesses. See `./cfo_supervisor.sh` for one way to
//! arrange that.
//!
//! After the fuzzing loop, CFO collects a list of seeds, some of which are failing. Next, it
//! merges, this list into previous set of seeds (persisting seeds is to be implemented, at the
//! moment the old list is always empty).
//!
//! Rules for merging:
//!
//! - Keep seeds for at most `commit_count_max` distinct commits.
//! - Prefer fresher commits (based on commit time stamp).
//! - For each commit and fuzzer combination, keep at most `seed_count_max` seeds.
//! - Prefer failing seeds to successful seeds.
//! - Prefer older seeds.
//!
//! These rules ensure that in the steady state (assuming fuzzer's clock doesn't fail) the set of
//! seeds is stable. If the clock goes backwards, there might be churn in the set of a seed, but the
//! number of failing seeds will never decrease.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");
const flags = @import("../flags.zig");
const fatal = flags.fatal;
const Shell = @import("../shell.zig");

pub const CliArgs = struct {
    budget_minutes: u64 = 10,
    hang_minutes: u64 = 30,
    concurrency: ?u32 = null,
};

const Fuzzer = enum {
    canary,
    ewah,
    lsm_cache_map,
    lsm_forest,
    lsm_manifest_level,
    lsm_manifest_log,
    lsm_segmented_array,
    lsm_tree,
    vsr_free_set,
    vsr_journal_format,
    vsr_superblock_quorums,
    vsr_superblock,
    vopr,
    vopr_testing,

    fn print_command(fuzzer: Fuzzer, shell: *Shell, seed: u64) ![]const u8 {
        if (fuzzer == .vopr or fuzzer == .vopr_testing) {
            const state_machine: []const u8 =
                if (fuzzer == .vopr) "" else " -Dsimulator-state-machine=testing";
            return try shell.print(
                "./zig/zig build -Drelease{s} simulator_run -- {d}",
                .{ state_machine, seed },
            );
        }
        return try shell.print(
            "./zig/zig build -Drelease fuzz -- --seed={d} {s}",
            .{ seed, @tagName(fuzzer) },
        );
    }

    fn spawn_command(fuzzer: Fuzzer, shell: *Shell, seed: u64) !std.ChildProcess {
        if (fuzzer == .vopr or fuzzer == .vopr_testing) {
            const state_machine: []const []const u8 =
                if (fuzzer == .vopr) &.{} else &.{"-Dsimulator-state-machine=testing"};
            return try shell.spawn_options(
                .{ .stdin_behavior = .Pipe },
                "{zig} build -Drelease {state_machine} simulator_run -- {seed}",
                .{
                    .zig = shell.zig_exe.?,
                    .state_machine = state_machine,
                    .seed = seed,
                },
            );
        }
        return try shell.spawn_options(
            .{ .stdin_behavior = .Pipe },
            "{zig} build -Drelease fuzz -- --seed={seed} {fuzzer}",
            .{
                .zig = shell.zig_exe.?,
                .seed = seed,
                .fuzzer = @tagName(fuzzer),
            },
        );
    }
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CliArgs) !void {
    if (builtin.os.tag == .windows) {
        return error.NotSupported;
    }

    assert(try shell.exec_status_ok("git --version", .{}));

    // Read-write token for <https://github.com/tigerbeetle/devhubdb>.
    const devhub_token_option = shell.env_get_option("DEVHUBDB_PAT");
    if (devhub_token_option == null) {
        log.err("'DEVHUB_PAT' environmental variable is not set, will not upload results", .{});
    }

    // Readonly token for PR metadata of <https://github.com/tigerbeetle/tigerbeetle>.
    const gh_token_option = shell.env_get_option("GH_TOKEN");
    if (gh_token_option == null) {
        log.err("'GH_TOKEN' environmental variable is not set, will not fetch pull requests", .{});
    } else {
        assert(try shell.exec_status_ok("gh --version", .{}));
    }

    var seeds = std.ArrayList(SeedRecord).init(shell.arena.allocator());
    try run_fuzzers(shell, &seeds, gh_token_option, .{
        .concurrency = cli_args.concurrency orelse try std.Thread.getCpuCount(),
        .budget_seconds = cli_args.budget_minutes * std.time.s_per_min,
        .hang_seconds = cli_args.hang_minutes * std.time.s_per_min,
    });
    if (devhub_token_option) |token| {
        try upload_results(shell, gpa, token, seeds.items);
    } else {
        log.info("skipping upload, no token", .{});
        for (seeds.items) |seed_record| {
            const seed_record_json = try std.json.stringifyAlloc(
                shell.arena.allocator(),
                seed_record,
                .{},
            );
            log.info("{s}", .{seed_record_json});
        }
    }
}

fn run_fuzzers(
    shell: *Shell,
    seeds: *std.ArrayList(SeedRecord),
    gh_token: ?[]const u8,
    options: struct {
        concurrency: usize,
        budget_seconds: u64,
        hang_seconds: u64,
    },
) !void {
    const tasks = try run_fuzzers_prepare_tasks(shell, gh_token);

    const random = std.crypto.random;

    try shell.zig("build -Drelease build_fuzz", .{});

    const FuzzerChild = struct {
        child: std.ChildProcess,
        seed: SeedRecord,
    };

    var fuzzers = try shell.arena.allocator().alloc(?FuzzerChild, options.concurrency);
    @memset(fuzzers, null);
    defer for (fuzzers) |*fuzzer_or_null| {
        if (fuzzer_or_null.*) |*fuzzer| {
            _ = fuzzer.child.kill() catch {};
            fuzzer_or_null.* = null;
        }
    };

    const total_budget_seconds = options.budget_seconds + options.hang_seconds;
    for (0..total_budget_seconds) |second| {
        const last_iteration = second == total_budget_seconds - 1;

        if (second < options.budget_seconds) {
            // Start new fuzzer processes if we have more time.
            for (fuzzers) |*fuzzer_or_null| {
                if (fuzzer_or_null.* == null) {
                    const task_index = random.weightedIndex(u32, tasks.weight);
                    const working_directory = tasks.working_directory[task_index];
                    var seed_record = tasks.seed_record[task_index];

                    try shell.pushd(working_directory);
                    defer shell.popd();

                    assert(try shell.dir_exists(".git"));

                    seed_record.seed = random.int(u64);
                    seed_record.seed_timestamp_start = @intCast(std.time.timestamp());
                    seed_record.command =
                        try seed_record.fuzzer.print_command(shell, seed_record.seed);

                    log.debug("will start '{s}'", .{seed_record.command});
                    const child = try seed_record.fuzzer.spawn_command(shell, seed_record.seed);
                    _ = try std.os.fcntl(
                        child.stdin.?.handle,
                        std.os.F.SETFD,
                        @as(u32, std.os.O.NONBLOCK),
                    );
                    fuzzer_or_null.* = .{ .seed = seed_record, .child = child };
                }
            }
        }

        // Wait for a second before polling for completion.
        std.time.sleep(1 * std.time.ns_per_s);

        var running_count: u32 = 0;
        for (fuzzers) |*fuzzer_or_null| {
            // Poll for completed fuzzers.
            if (fuzzer_or_null.*) |*fuzzer| {
                running_count += 1;

                var fuzzer_done = false;
                _ = fuzzer.child.stdin.?.write(&.{1}) catch |err| {
                    switch (err) {
                        error.WouldBlock => {},
                        error.BrokenPipe => fuzzer_done = true,
                        else => return err,
                    }
                };

                if (fuzzer_done or last_iteration) {
                    log.debug("will reap '{s}'", .{fuzzer.seed.command});
                    const term = try if (fuzzer_done) fuzzer.child.wait() else fuzzer.child.kill();
                    var seed_record = fuzzer.seed;
                    seed_record.ok = std.meta.eql(term, .{ .Exited = 0 });
                    seed_record.seed_timestamp_end = @intCast(std.time.timestamp());
                    try seeds.append(seed_record);
                    fuzzer_or_null.* = null;
                }
            }
        }

        if (second < options.budget_seconds) {
            assert(running_count == options.concurrency);
        }
        if (running_count == 0) break;
    }
}

fn run_fuzzers_prepare_tasks(shell: *Shell, gh_token: ?[]const u8) !struct {
    working_directory: [][]const u8,
    seed_record: []SeedRecord,
    weight: []u32,
} {
    var working_directory = std.ArrayList([]const u8).init(shell.arena.allocator());
    var seed_record = std.ArrayList(SeedRecord).init(shell.arena.allocator());

    // Fuzz an independent clone of the repository, so that CFO and the fuzzer could be on
    // different branches (to fuzz PRs and releases).
    shell.project_root.deleteTree("working") catch {};

    { // Main branch fuzzing.
        try shell.cwd.makePath("./working/main");
        try shell.pushd("./working/main");
        defer shell.popd();

        const commit = try run_fuzzers_prepare_repository(shell, .main_branch);
        log.info("fuzzing commit={s} timestamp={d}", .{ commit.sha, commit.timestamp });

        for (std.enums.values(Fuzzer)) |fuzzer| {
            try working_directory.append("./working/main");
            try seed_record.append(.{
                .commit_timestamp = commit.timestamp,
                .commit_sha = commit.sha,
                .fuzzer = fuzzer,
                .branch = "https://github.com/tigerbeetle/tigerbeetle",
            });
        }
    }
    const task_main_count: u32 = @intCast(seed_record.items.len);

    if (gh_token != null) {
        // Any PR labeled like 'fuzz lsm_tree'
        const GhPullRequest = struct {
            const Label = struct {
                id: []const u8,
                name: []const u8,
                description: []const u8,
                color: []const u8,
            };
            number: u32,
            labels: []Label,
        };

        const pr_list_text = try shell.exec_stdout(
            "gh pr list --state open --json number,labels",
            .{},
        );
        const pr_list = try std.json.parseFromSliceLeaky(
            []GhPullRequest,
            shell.arena.allocator(),
            pr_list_text,
            .{},
        );

        for (pr_list) |pr| {
            for (pr.labels) |label| {
                if (stdx.cut(label.name, "fuzz ") != null) break;
            } else continue;

            const pr_directory = try shell.print("./working/{d}", .{pr.number});
            try shell.cwd.makePath(pr_directory);
            try shell.pushd(pr_directory);
            defer shell.popd();

            const commit = try run_fuzzers_prepare_repository(
                shell,
                .{ .pull_request = pr.number },
            );
            log.info("fuzzing commit={s} timestamp={d}", .{ commit.sha, commit.timestamp });

            var pr_fuzzers_count: u32 = 0;
            for (std.enums.values(Fuzzer)) |fuzzer| {
                const labeled = for (pr.labels) |label| {
                    if (stdx.cut(label.name, "fuzz ")) |cut| {
                        if (std.mem.eql(u8, cut.suffix, @tagName(fuzzer))) {
                            break true;
                        }
                    }
                } else false;

                if (labeled or fuzzer == .canary) {
                    pr_fuzzers_count += 1;
                    try working_directory.append(pr_directory);
                    try seed_record.append(.{
                        .commit_timestamp = commit.timestamp,
                        .commit_sha = commit.sha,
                        .fuzzer = fuzzer,
                        .branch = try shell.print(
                            "https://github.com/tigerbeetle/tigerbeetle/pull/{d}",
                            .{pr.number},
                        ),
                    });
                }
            }
            assert(pr_fuzzers_count >= 2); // The canary and at least one different fuzzer.
        }
    }
    const task_pr_count: u32 = @intCast(seed_record.items.len - task_main_count);

    // Split time 50:50 between fuzzing main and fuzzing labeled PRs.
    const weight = try shell.arena.allocator().alloc(u32, working_directory.items.len);
    var weight_main_total: usize = 0;
    var weight_pr_total: usize = 0;
    for (weight[0..task_main_count]) |*weight_main| {
        weight_main.* = @max(task_pr_count, 1);
        weight_main_total += weight_main.*;
    }
    for (weight[task_main_count..]) |*weight_pr| {
        weight_pr.* = @max(task_main_count, 1);
        weight_pr_total += weight_pr.*;
    }
    if (weight_main_total > 0 and weight_pr_total > 0) {
        assert(weight_main_total == weight_pr_total);
    }

    return .{
        .working_directory = working_directory.items,
        .seed_record = seed_record.items,
        .weight = weight,
    };
}

const Commit = struct {
    sha: [40]u8,
    timestamp: u64,
};

// Clones the specified branch or pull request, builds the code and returns the commit that the
// branch/PR resolves to.
fn run_fuzzers_prepare_repository(shell: *Shell, target: union(enum) {
    main_branch,
    pull_request: u32,
}) !Commit {
    const commit = switch (target) {
        .main_branch => commit: {
            // NB: for the main branch, carefully checkout the commit of the CFO itself, and not
            // just the current tip of the branch. This way, it is easier to atomically adjust
            // fuzzers and CFO.
            const commit = try run_fuzzers_commit_info(shell);
            try shell.exec("git clone https://github.com/tigerbeetle/tigerbeetle .", .{});
            try shell.exec(
                "git switch --detach {commit}",
                .{ .commit = @as([]const u8, &commit.sha) },
            );
            break :commit commit;
        },
        .pull_request => |pr_number| commit: {
            try shell.exec(
                "git fetch origin refs/pull/{pr_number}/head",
                .{ .pr_number = pr_number },
            );
            try shell.exec("git switch --detach FETCH_HEAD", .{});
            break :commit try run_fuzzers_commit_info(shell);
        },
    };
    return commit;
}

fn run_fuzzers_commit_info(shell: *Shell) !Commit {
    const commit_sha: [40]u8 = commit_sha: {
        const commit_str = try shell.exec_stdout("git rev-parse HEAD", .{});
        assert(commit_str.len == 40);
        break :commit_sha commit_str[0..40].*;
    };
    const commit_timestamp = commit_timestamp: {
        const timestamp = try shell.exec_stdout(
            "git show -s --format=%ct {sha}",
            .{ .sha = @as([]const u8, &commit_sha) },
        );
        break :commit_timestamp try std.fmt.parseInt(u64, timestamp, 10);
    };
    return .{ .sha = commit_sha, .timestamp = commit_timestamp };
}

fn upload_results(
    shell: *Shell,
    gpa: std.mem.Allocator,
    token: []const u8,
    seeds_new: []const SeedRecord,
) !void {
    log.info("uploading {} seeds", .{seeds_new.len});

    _ = try shell.cwd.deleteTree("./devhubdb");
    try shell.exec(
        \\git clone --depth 1
        \\  https://oauth2:{token}@github.com/tigerbeetle/devhubdb.git
        \\  devhubdb
    , .{
        .token = token,
    });
    try shell.pushd("./devhubdb");
    defer shell.popd();

    for (0..32) |_| {
        // As we need a retry loop here to deal with git conflicts, let's use per-iteration arena.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        try shell.exec("git fetch origin", .{});
        try shell.exec("git reset --hard origin/main", .{});

        const max_size = 1024 * 1024;
        const data = try shell.cwd.readFileAlloc(
            arena.allocator(),
            "./fuzzing/data.json",
            max_size,
        );

        const seeds_old = try std.json.parseFromSliceLeaky(
            []SeedRecord,
            arena.allocator(),
            data,
            .{},
        );

        switch (try SeedRecord.merge(arena.allocator(), .{}, seeds_old, seeds_new)) {
            .up_to_date => {
                log.info("seeds already up to date", .{});
                break;
            },
            .updated => |seeds_merged| {
                const json = try std.json.stringifyAlloc(
                    shell.arena.allocator(),
                    seeds_merged,
                    .{ .whitespace = .indent_2 },
                );
                try shell.cwd.writeFile("./fuzzing/data.json", json);
                try shell.exec("git add ./fuzzing/data.json", .{});
                try shell.git_env_setup();
                try shell.exec("git commit -m 🌱", .{});
                if (shell.exec("git push", .{})) {
                    log.info("seeds updated", .{});
                    break;
                } else |_| {
                    log.info("conflict, retrying", .{});
                }
            },
        }
    } else {
        log.err("can't push new data to devhub", .{});
        return error.CanNotPush;
    }
}

const SeedRecord = struct {
    const MergeOptions = struct {
        commit_count_max: u32 = 32,
        seed_count_max: u32 = 4,
    };

    // NB: The order of fields is significant and defines comparison.
    commit_timestamp: u64, // compared in inverse order
    commit_sha: [40]u8,
    fuzzer: Fuzzer,
    ok: bool = false,
    seed_timestamp_start: u64 = 0,
    seed_timestamp_end: u64 = 0,
    seed: u64 = 0,
    // The following fields are excluded from comparison:
    command: []const u8 = "",
    // Branch is an GitHub URL. It only affects the UI, where the seeds are grouped by the branch.
    branch: []const u8,

    fn order(a: SeedRecord, b: SeedRecord) std.math.Order {
        inline for (comptime std.meta.fieldNames(SeedRecord)) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "command")) continue;
            if (comptime std.mem.eql(u8, field_name, "branch")) continue;

            const a_field = @field(a, field_name);
            const b_field = @field(b, field_name);

            const field_order = switch (@TypeOf(@field(a, field_name))) {
                [40]u8 => std.mem.order(u8, &a_field, &b_field),
                bool => std.math.order(@intFromBool(a_field), @intFromBool(b_field)),
                Fuzzer => std.math.order(@intFromEnum(a_field), @intFromEnum(b_field)),
                else => std.math.order(a_field, b_field),
            };

            if (field_order != .eq) {
                if (comptime std.mem.eql(u8, field_name, "commit_timestamp")) {
                    return field_order.invert();
                }
                return field_order;
            }
        }
        return .eq;
    }

    fn less_than(_: void, a: SeedRecord, b: SeedRecord) bool {
        return a.order(b) == .lt;
    }

    // Merges two sets of seeds keeping the more interesting one. A direct way to write this would
    // be to group the seeds by commit & fuzzer and do a union of nested hash maps, but that's a
    // pain to implement in Zig. Luckily, by cleverly implementing the ordering on seeds it is
    // possible to implement the merge by concatenation, sorting, and a single-pass counting scan.
    fn merge(
        arena: std.mem.Allocator,
        options: MergeOptions,
        current: []const SeedRecord,
        new: []const SeedRecord,
    ) !union(enum) { updated: []const SeedRecord, up_to_date } {
        var current_and_new = try std.mem.concat(arena, SeedRecord, &.{ current, new });
        std.mem.sort(SeedRecord, current_and_new, {}, SeedRecord.less_than);

        var result = try std.ArrayList(SeedRecord).initCapacity(arena, current.len);

        var commit_sha_previous: ?[40]u8 = null;
        var commit_count: u32 = 0;

        var fuzzer_previous: ?Fuzzer = null;

        var seed_previous: ?u64 = null;
        var seed_count: u32 = 0;

        for (current_and_new) |record| {
            if (commit_sha_previous == null or
                !std.meta.eql(commit_sha_previous.?, record.commit_sha))
            {
                commit_sha_previous = record.commit_sha;
                commit_count += 1;
                fuzzer_previous = null;
            }

            if (commit_count > options.commit_count_max) {
                break;
            }

            if (fuzzer_previous == null or
                fuzzer_previous.? != record.fuzzer)
            {
                fuzzer_previous = record.fuzzer;
                seed_previous = null;
                seed_count = 0;
            }

            if (seed_previous == record.seed) {
                continue;
            }
            seed_previous = record.seed;

            seed_count += 1;
            if (seed_count <= options.seed_count_max) {
                try result.append(record);
            }
        }

        if (result.items.len != current.len) {
            return .{ .updated = result.items };
        }
        for (result.items, current) |new_record, current_record| {
            if (new_record.order(current_record) != .eq) {
                return .{ .updated = result.items };
            }
        }
        return .up_to_date;
    }
};

test "cfo: SeedRecord.merge" {
    const Snap = @import("../testing/snaptest.zig").Snap;
    const snap = Snap.snap;

    const T = struct {
        fn check(current: []const SeedRecord, new: []const SeedRecord, want: Snap) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            const options = SeedRecord.MergeOptions{
                .commit_count_max = 2,
                .seed_count_max = 2,
            };
            const got = switch (try SeedRecord.merge(arena.allocator(), options, current, new)) {
                .up_to_date => current,
                .updated => |updated| updated,
            };
            try want.diff_json(got, .{ .whitespace = .indent_2 });
        }
    };

    try T.check(&.{}, &.{}, snap(@src(),
        \\[]
    ));

    try T.check(
        &.{
            // First commit, one failure.
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
            //  Second commit, two successes.
            .{
                .commit_timestamp = 2,
                .commit_sha = .{'2'} ** 40,
                .fuzzer = .ewah,
                .ok = true,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
            .{
                .commit_timestamp = 2,
                .commit_sha = .{'2'} ** 40,
                .fuzzer = .ewah,
                .ok = true,
                .seed_timestamp_start = 2,
                .seed_timestamp_end = 2,
                .seed = 2,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        &.{
            // Two new failures for the first commit, one will be added.
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 2,
                .seed_timestamp_end = 2,
                .seed = 2,
                .command = "fuzz ewah",
                .branch = "main",
            },
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 3,
                .seed_timestamp_end = 3,
                .seed = 3,
                .command = "fuzz ewah",
                .branch = "main",
            },
            // One failure for the second commit, it will replace one success.
            .{
                .commit_timestamp = 2,
                .commit_sha = .{'2'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 4,
                .seed_timestamp_end = 4,
                .seed = 4,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        snap(@src(),
            \\[
            \\  {
            \\    "commit_timestamp": 2,
            \\    "commit_sha": "2222222222222222222222222222222222222222",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 4,
            \\    "seed_timestamp_end": 4,
            \\    "seed": 4,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  },
            \\  {
            \\    "commit_timestamp": 2,
            \\    "commit_sha": "2222222222222222222222222222222222222222",
            \\    "fuzzer": "ewah",
            \\    "ok": true,
            \\    "seed_timestamp_start": 1,
            \\    "seed_timestamp_end": 1,
            \\    "seed": 1,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  },
            \\  {
            \\    "commit_timestamp": 1,
            \\    "commit_sha": "1111111111111111111111111111111111111111",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 1,
            \\    "seed_timestamp_end": 1,
            \\    "seed": 1,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  },
            \\  {
            \\    "commit_timestamp": 1,
            \\    "commit_sha": "1111111111111111111111111111111111111111",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 2,
            \\    "seed_timestamp_end": 2,
            \\    "seed": 2,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  }
            \\]
        ),
    );

    try T.check(
        &.{
            // Two failing commits.
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
            .{
                .commit_timestamp = 2,
                .commit_sha = .{'2'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        &.{
            // A new successful commit displaces the older failure.
            .{
                .commit_timestamp = 3,
                .commit_sha = .{'3'} ** 40,
                .fuzzer = .ewah,
                .ok = true,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        snap(@src(),
            \\[
            \\  {
            \\    "commit_timestamp": 3,
            \\    "commit_sha": "3333333333333333333333333333333333333333",
            \\    "fuzzer": "ewah",
            \\    "ok": true,
            \\    "seed_timestamp_start": 1,
            \\    "seed_timestamp_end": 1,
            \\    "seed": 1,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  },
            \\  {
            \\    "commit_timestamp": 2,
            \\    "commit_sha": "2222222222222222222222222222222222222222",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 1,
            \\    "seed_timestamp_end": 1,
            \\    "seed": 1,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  }
            \\]
        ),
    );

    // Deduplicates identical seeds
    try T.check(
        &.{
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        &.{
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 1,
                .seed_timestamp_end = 1,
                .seed = 1,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        snap(@src(),
            \\[
            \\  {
            \\    "commit_timestamp": 1,
            \\    "commit_sha": "1111111111111111111111111111111111111111",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 1,
            \\    "seed_timestamp_end": 1,
            \\    "seed": 1,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  }
            \\]
        ),
    );

    // Prefer older seeds rather than smaller seeds.
    try T.check(
        &.{
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 10,
                .seed_timestamp_end = 10,
                .seed = 10,
                .command = "fuzz ewah",
                .branch = "main",
            },
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 20,
                .seed_timestamp_end = 20,
                .seed = 20,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        &.{
            .{
                .commit_timestamp = 1,
                .commit_sha = .{'1'} ** 40,
                .fuzzer = .ewah,
                .ok = false,
                .seed_timestamp_start = 5,
                .seed_timestamp_end = 5,
                .seed = 999,
                .command = "fuzz ewah",
                .branch = "main",
            },
        },
        snap(@src(),
            \\[
            \\  {
            \\    "commit_timestamp": 1,
            \\    "commit_sha": "1111111111111111111111111111111111111111",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 5,
            \\    "seed_timestamp_end": 5,
            \\    "seed": 999,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  },
            \\  {
            \\    "commit_timestamp": 1,
            \\    "commit_sha": "1111111111111111111111111111111111111111",
            \\    "fuzzer": "ewah",
            \\    "ok": false,
            \\    "seed_timestamp_start": 10,
            \\    "seed_timestamp_end": 10,
            \\    "seed": 10,
            \\    "command": "fuzz ewah",
            \\    "branch": "main"
            \\  }
            \\]
        ),
    );
}