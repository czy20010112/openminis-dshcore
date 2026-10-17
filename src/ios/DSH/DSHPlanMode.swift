//
//  DSHPlanMode.swift
//  Minis
//
//  Plan mode: explore and produce a plan, then leave the mode and implement.
//
//  Ported from DSH's `plan-mode` package (`packages/plan/plan-mode`). The
//  behaviour that matters is the same:
//
//    * entering is a user action — `/plan` in the composer, or the `/` menu;
//    * while active, a policy section is added to the system prompt telling the
//      model to explore with non-mutating reads and to plan rather than execute;
//    * the mode ends through the `exit_plan_mode` tool, which is the model's only
//      way out;
//    * `todo_write` is explicitly NOT for the planning phase — it tracks the
//      implementation after the plan is accepted. DSH states this in the policy
//      text and this port keeps it.
//
//  The one section of DSH's behaviour that was missing in the first port is now
//  implemented. DSH routes `exit_plan_mode` through a user-questions approval
//  channel and stays in plan mode unless the user picks "Approve". The first
//  port had no channel wired to tools, so the call approved itself and left the
//  mode — the operator's report was "nothing happened and it got approved".
//  `exit` now suspends on `DSHPlanApproval` (the review channel: sheet, two
//  options, optional feedback) and no longer decides anything by itself.
//
//  Every non-approving answer — keep planning (with or without feedback), a
//  dismissed review, a cancelled turn, a review that outlived its deadline —
//  returns to the model as an ERROR and leaves the mode on, exactly as DSH does.
//
//  Mutating tools are in fact blocked here (see `refusal(forTool:arguments:)`).
//  That is a deliberate local addition, not a port: DSH enforces nothing, it says
//  its sandbox mode and approval policy are enforced independently and never read
//  plan state. What the addition must not do is starve the mode of the
//  information a plan needs — that was the operator's second report ("plan模式
//  shell 全部禁用是不是有点严格了，网络搜索呢…信息不足不足以做计划"), and it is
//  answered by the classifier below: reads and searches stay open, only mutation
//  is closed.
//
//  The operator reported that plan mode did nothing: the model "made no plan at
//  all and just started". The section WAS reaching the request — measured, not
//  inferred: `[DSH] prompt sections=[…] chars=… planMode=true` reports 29292
//  characters against 27243 with the mode off, a 2049-character delta that is
//  exactly this section (2047) plus `renderPrompt`'s two-character join. What was
//  weak was the text, which the first port had shortened; `policyText` below now
//  carries the upstream section verbatim. The other half of that report — "it
//  only planned after I told it in prose" — is what a section that forbids
//  *mutation* but never says "do not carry out the request at all" produces on a
//  read-only task: `yes … | head -3` edits nothing, so the policy as trimmed did
//  not cover it, while upstream's "Stay in plan mode until the user approves your
//  plan through exit_plan_mode" and "do not proceed with implementation" do.
//

import Foundation

public enum DSHPlanMode {

    /// Where the policy section sits. DSH's `PLAN_POLICY` is 500, ahead of its
    /// tool guidance at 1000, because the plan rules have to win over any later
    /// tool description that suggests mutating something. The same ordering is
    /// kept here.
    public static let sectionOrder = 500

    /// The section registered while plan mode is active.
    ///
    /// Registered for the life of the turn either way: when the mode is off the
    /// section renders as the empty string, which `DSHSystemPrompt` drops. DSH
    /// adds and removes the section instead, and notes the tool catalog is held
    /// constant across modes for request-cache stability — keeping the section
    /// position fixed is the same idea applied to the prompt.
    public static func policySection() -> DSHPromptSection {
        DSHPromptSection(
            name: "plan:policy",
            order: sectionOrder,
            dynamic: { _ in
                guard DSHTodoStore.shared.planModeActive else { return "" }
                return policyText
            }
        )
    }

    /// DSH's policy text, verbatim.
    ///
    /// Source: the deployment that owns the section,
    /// `packages/bundle/base/cordis.patch.yml` — the `plan-mode` entry's
    /// `section` (upstream `dsh-checkout`, 0.2.1-rc.2, lines 332-346). That file
    /// is the authority for the wording, not this port: the model was tuned
    /// against it.
    ///
    /// The first port shortened it. Two of the dropped sentences are what made
    /// the mode bind, and both are back:
    ///
    ///   * "it presents the plan **for approval**, and implementation begins only
    ///     in a later step **after approval**" — the port had written "after it is
    ///     called", which told the model its own `exit_plan_mode` call was what
    ///     starts implementation. That was true while the call approved itself;
    ///     `exit` now waits on `DSHPlanApproval`, so the stale sentence was both
    ///     weaker and false.
    ///   * "If review rejects it, incorporate the feedback and present again. If
    ///     the review channel is unavailable or aborted, stay in plan mode and ask
    ///     the user to switch modes manually; **do not proceed with
    ///     implementation**." — the port dropped this because it then had no
    ///     review channel. It has one now, and every non-approving path in `exit`
    ///     returns one of these situations to the model, so the model needs to be
    ///     told what to do in them.
    ///
    /// Two clauses name `ask_user_question`, which is not a tool in this app
    /// (the roster is `makeAgentTools()`; the plan review is not a general
    /// question channel). Both are reworded, and those two rewrites are the only
    /// deviations from the upstream text:
    ///
    ///   * "Use ask_user_question only for user-owned choices…" becomes "Ask the
    ///     user only for user-owned choices…";
    ///   * "…through prose or ask_user_question." becomes "…through prose."
    ///
    /// Everything else — including the `todo_write` exclusion, which is how the
    /// implementation checklist stays separate from the plan — is upstream's
    /// exact sentence.
    ///
    /// Alignment is checkable, not asserted: the literal's first eleven lines (six
    /// paragraphs and the five blank lines between them) reproduce the snapshot at
    /// `verify/_tmp-upstream/cordis-rc2.yml` lines 336-346 character for character
    /// once the two `ask_user_question` rewrites above are applied, and everything
    /// after them is one appended paragraph. `node _tools/planmode-policy-align.cjs`
    /// reports both facts, and exits 0 only while they hold:
    ///
    ///     swift    : 7 paragraph(s), 3237 chars literal / 3500 rendered
    ///     upstream : 6 paragraph(s), 2330 chars (2 documented rewrites applied)
    ///     P1..P6 identical
    ///     appended P7 starts with "In this app" marker (905 chars literal, 1168 rendered)
    ///
    /// The seventh paragraph — "In this app, plan mode still reads." — is the
    /// local addition the operator asked for: they reported that refusing every
    /// shell command in plan mode left the model short of the information a plan
    /// needs ("信息不足不足以做计划") and asked that the re-opened capabilities be
    /// written into the plan-mode prompt so the model uses them on the first try.
    /// It is appended, never interleaved, so upstream's sentences stay untouched;
    /// the marker "In this app" is there so a future reader can tell at a glance
    /// which text is a port and which is a local policy decision. It must stay in
    /// step with `shellCommandVerdict`: the list it hands the model is the list
    /// the scheduler actually enforces.
    ///
    /// The message plan mode hands back when the model reaches for a tool that
    /// would carry the plan out, or nil when the tool is allowed. A per-call
    /// decision: `shell_execute` is judged by its `command` argument.
    ///
    /// DSH leaves the tool catalog identical across modes and relies on the policy
    /// text alone — its own README calls plan mode "guidance, not enforcement".
    /// Measured on this device that guidance does not hold: with the policy section
    /// demonstrably in the request (30 590 characters with plan mode on against
    /// 29 292 off) the model called `shell_execute` thirteen seconds in and ran the
    /// operator's command, which is exactly the complaint that started this.
    ///
    /// So the refusal is mechanical. What is refused is *mutation*, not
    /// inspection: `file_write`, `file_edit`, `memory_write` and `todo_write`
    /// outright (`todo_write` because DSH's policy says the checklist tracks
    /// implementation after approval, not the planning phase), and `shell_execute`
    /// unless `shellCommandVerdict` can prove the command is read-only.
    ///
    /// The first version refused `shell_execute` without looking at the command,
    /// on the reasoning that a read-only command could not be told from a
    /// destructive one without running it. The operator rejected that: the mode
    /// then could not gather enough information to plan. The classifier below is
    /// the answer to the actual problem — the two *can* be told apart, statically,
    /// for the commands planning uses — and it keeps the property that mattered:
    /// the decision is made before anything runs, so a refusal costs nothing.
    static func refusal(forTool name: String, arguments: [String: Any]) -> String? {
        guard DSHTodoStore.shared.planModeActive else { return nil }
        switch name {
        case "file_write":
            return denied(name, "it writes a file, which would carry the plan out rather than produce it") +
                inspectionFooter
        case "file_edit":
            return denied(name, "it edits a file on disk, which would carry the plan out rather than produce it") +
                inspectionFooter
        case "memory_write":
            return denied(name, "it would persist a change to memory instead of reading it") +
                inspectionFooter
        case "todo_write":
            return """
            Refused: `todo_write` is not available while plan mode is on. DSH's plan \
            policy reserves it for the implementation checklist after an approved \
            plan; the plan itself belongs in `exit_plan_mode`. Keep the steps you are \
            weighing in the plan text.
            """
        case "shell_execute":
            guard let command = planCommand(from: arguments) else {
                return denied(
                    name,
                    "this call carries no `command` string to check, so it cannot be shown to be read-only"
                ) + inspectionFooter
            }
            let verdict = shellCommandVerdict(command)
            guard verdict.allowed else {
                return "Refused: `shell_execute` is not available while plan mode is on — "
                    + verdict.reason
                    + ". Only read-only inspection commands are allowed during planning: "
                    + "\(readOnlyCommandSummary). Re-run the inspection with one of those, "
                    + "or without chaining, and leave the changing command out of the plan "
                    + "— describe it in the plan instead."
            }
            return nil
        default:
            return nil
        }
    }

    /// The plan-mode refusal for a tool that has no read-only form, with the
    /// standing list of what to explore with instead.
    private static func denied(_ tool: String, _ why: String) -> String {
        "Refused: `\(tool)` is not available while plan mode is on — \(why)."
    }

    private static let inspectionFooter =
        " Plan mode is for producing a plan, not for carrying it out; the plan is "
        + "submitted through `exit_plan_mode` and implementation begins only after "
        + "it is approved. Keep gathering information: web_search, file_read, "
        + "memory_get, read_image, browser_use and read-only shell_execute commands "
        + "are all still available."

    /// The `command` a `shell_execute` call would run, or nil when the call has no
    /// usable one. A missing command is refused rather than assumed: an
    /// unclassifiable call is exactly what this check exists to catch.
    static func planCommand(from arguments: [String: Any]) -> String? {
        guard let command = arguments["command"] as? String, !command.isEmpty else { return nil }
        return command
    }

    // MARK: - Read-only shell classifier
    //
    // Plan mode's shell rule, as a pure function of the command text. It runs
    // before the command does, so the decision has to be made from the string —
    // and that is the whole point of the design: nothing here executes anything,
    // and a refusal costs nothing.
    //
    // Two branches, both required to be data — a reviewer can check the tables
    // without reading the algorithm:
    //
    //   1. Split the command into sub-commands at `;`, `&`, `|` and newlines,
    //      keeping quoting and backslash escapes intact, then take each
    //      sub-command's argv (wrapper programs peeled, see `wrapperCommands`).
    //      Flags are collected from every position, and a banned word, a banned
    //      flag, a redirect or a substitution refuses the whole command wherever
    //      it appears. Otherwise *every* sub-command's program must be in
    //      `allowedCommands` — that is the allowlist branch, and it is what makes
    //      the rule fail closed: `python -c …`, `sed -i …` and `curl … | sh` are
    //      refused because they are not on the list, not because a blacklist
    //      happened to name them.
    //   2. `git` gets a narrower second check, because its program is read-only
    //      for some sub-commands and mutating for others. The sub-command is
    //      resolved first: a word in `gitReadOnlySubcommands` is accepted (with
    //      its operands still checked, since `branch` and `remote` read bare and
    //      write with an operand), a word in `gitMutatingWords` is refused by
    //      name, and anything else is refused as an unknown sub-command.
    //
    // The tables below are the whole rule; the algorithm only applies them.

    /// The verdict for one shell command in plan mode.
    ///
    /// `rule` and `words` exist for the evidence script: they let a sample be
    /// checked against the table that decided it instead of against a bare yes/no,
    /// which is what makes an unexpected verdict attributable to a rule.
    struct ShellCommandVerdict {
        let allowed: Bool
        /// Model-facing, and non-empty only when `allowed` is false: which rule
        /// was hit, named in terms of the command that hit it.
        let reason: String
        let rule: String
        /// The argv words the command was reduced to, after wrapper peeling.
        let words: [String]
        let firstWord: String?
    }

    /// Programs whose argv[0] is accepted as a read-only inspection. Every
    /// sub-command of the call must start with one of these. `git` is here and is
    /// additionally restricted by `gitReadOnlySubcommands` / `gitMutatingWords`
    /// as described above.
    ///
    /// Kept to the inspection commands a plan actually needs.
    static let allowedCommands: [String] = [
        "pwd", "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "file",
        "stat", "du", "df", "echo", "which", "type", "git",
    ]

    /// Programs that only delegate: the word after them is the one that decides.
    /// Each is peeled together with its own flags and `VAR=value` assignments, so
    /// `env FOO=1 ls` and `sudo -n ls` classify as `ls` while `sudo rm -rf /` still
    /// hits the banned word. Nothing here writes, so peeling it cannot hide a
    /// writer — a wrapper is only ever a head if an allowed command follows it.
    static let wrapperCommands: [String] = [
        "sudo", "doas", "env", "nice", "ionice", "command", "nohup", "time",
    ]

    /// Shell words that refuse the whole command wherever they appear, i.e. in any
    /// position: as a program (`rm x`), as the program of a later sub-command
    /// (`ls && rm x`), or as an operand (`which rm`). Each is matched as a whole
    /// word, so `rm` does not fire on `confirm` and `tee` does not fire on `teeth`.
    /// The redirects and chaining characters are not here: the scan turns those
    /// into their own words (`>`, `>>`, `&&`, `|`, `;`, backticks, brackets) and
    /// the gate matches them literally.
    static let dangerousWords: [(pattern: String, why: String)] = [
        ("rm", "it removes files"),
        ("mv", "it moves files"),
        ("cp", "it copies files over existing ones"),
        ("chmod", "it changes file permissions"),
        ("chown", "it changes file ownership"),
        ("dd", "it writes raw blocks"),
        ("tee", "it writes to files"),
        ("truncate", "it truncates a file"),
        ("kill", "it signals a process"),
        ("pkill", "it signals processes"),
        ("killall", "it signals processes"),
        ("pkg", "it installs or removes packages"),
        ("apk", "it installs or removes packages"),
        ("opkg", "it installs or removes packages"),
    ]


    /// Flag words that mean "write" in the tools that take them, checked as whole
    /// arguments. `--watch` is here because it re-runs the command.
    static let dangerousFlags: [String] = [
        "--write", "--write=", "--amend", "--hard", "--force", "--in-place",
        "--watch", "--watch=", "--update", "--update=",
    ]

    /// `git` sub-commands that only read. A `git` call whose first argument is one
    /// of these is allowed; the mutating list below decides the rest.
    static let gitReadOnlySubcommands: [String] = [
        "status", "log", "diff", "show", "branch", "remote",
    ]

    /// `git` sub-commands that change the repository, the working tree, or the
    /// index. A sub-command from this list is refused by name; an operand from it
    /// is refused where the read-only sub-commands have writing forms (`git remote
    /// add …`). `branch` and `remote` are in both lists on purpose: they read bare
    /// and write with an operand, and the read-only list is consulted first.
    static let gitMutatingWords: [String] = [
        "add", "commit", "push", "pull", "fetch", "checkout", "switch", "restore",
        "reset", "clean", "rebase", "merge", "tag", "stash", "apply", "am",
        "cherry-pick", "revert", "gc", "prune", "config", "init", "clone", "worktree",
        "update-index", "update-ref", "symbolic-ref", "remote", "branch",
    ]

    /// The command families the model is told it may use. Kept as (family, example
    /// commands) pairs so both the plan-mode paragraph and the `shell_execute`
    /// refusal render from one list — the two cannot drift, and each example is
    /// itself a word in `allowedCommands`.
    static let readOnlyCommandCategories: [(family: String, commands: String)] = [
        ("listing and locating", "ls, find, stat, file, du, df, pwd, which, type"),
        ("reading", "cat, head, tail"),
        ("searching", "grep, rg, wc"),
        ("printing a value", "echo"),
        ("git history and state read-only",
         "git status, git log, git diff, git show, git branch -a, git remote -v"),
    ]

    /// One sentence naming every read-only command, for both the plan paragraph
    /// and the refusal. `readOnlyCommandSummary` is the compact form of the same
    /// list for the places that want it inline.
    static let readOnlyCommandSentence =
        "read-only inspection commands only — "
        + readOnlyCommandCategories
            .map { "\($0.family) (\($0.commands))" }
            .joined(separator: ", ")

    static var readOnlyCommandSummary: String {
        readOnlyCommandCategories
            .map { "\($0.family) (\($0.commands))" }
            .joined(separator: "; ")
    }


    /// True when `text` contains `pattern` as a regular expression.
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// True when `text` contains `word` as a whole word.
    private static func hasWord(_ text: String, _ word: String) -> Bool {
        matches(text, "\\b" + word + "\\b")
    }

    /// Classify one `shell_execute` command for plan mode.
    ///
    /// Pure: no state, no I/O, no execution — the answer is a function of the
    /// string. That is what makes it checkable, and why the evidence script can
    /// drive the real thing rather than a description of it.
    static func shellCommandVerdict(_ command: String) -> ShellCommandVerdict {
        let lowered = command.lowercased()
        let characters = Array(lowered.unicodeScalars)

        // --- 1. Split into sub-commands, collecting words plus what the split saw.
        var segments: [[String]] = []
        var words: [String] = []
        var insideSingleQuote = false
        var insideDoubleQuote = false
        var current = ""
        var index = 0

        func flushWord() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }

        func flushSegment() {
            flushWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        while index < characters.count {
            let character = characters[index]

            // Inside single quotes every character is literal; a backslash is
            // literal too, so it is handled before that test.
            if character == "\\", index + 1 < characters.count {
                current.unicodeScalars.append(character)
                current.unicodeScalars.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "'", !insideDoubleQuote {
                insideSingleQuote.toggle()
                flushWord()
                index += 1
                continue
            }
            if character == "\"", !insideSingleQuote {
                insideDoubleQuote.toggle()
                flushWord()
                index += 1
                continue
            }
            if !insideSingleQuote, !insideDoubleQuote {
                if character == " " || character == "\t" {
                    flushWord()
                    index += 1
                    continue
                }
                if character == ";" || character == "\n" {
                    // A `;` or a newline ends the command and is itself a chaining
                    // construct, so it is emitted as its own word — the chain gate
                    // reads it there. Gluing it onto the previous word would leave
                    // `cat a; cat b` looking like two allowed commands.
                    flushWord()
                    words.append(";")
                    flushSegment()
                    index += 1
                    continue
                }
                if character == ">" || character == "<" || character == "|"
                    || character == "&" || character == "`" {
                    current.unicodeScalars.append(character)
                    index += 1
                    continue
                }
                if character == "(" || character == ")" {
                    // A bracket is a construct in its own right — `ls(x)` is `ls`
                    // plus a sub-shell — so it is emitted as its own word rather
                    // than glued onto the program name.
                    flushWord()
                    words.append(String(character))
                    index += 1
                    continue
                }
            }
            current.unicodeScalars.append(character)
            index += 1
        }
        flushSegment()

        // Truth for the whole check comes from `argv`: `argv[0]` is the program
        // each sub-command actually runs, never the tool or the redirect operand.
        //
        // Wrapper programs (`sudo`, `env`) delegate rather than do anything, so the
        // word after them is the target and they are peeled together with their own
        // flags and `VAR=value` assignments — `env FOO=1 ls` and `sudo -n ls`
        // classify as `ls`, while `sudo rm -rf /` still hits the banned word. A
        // wrapper taking an argument this cannot peel (`sudo -u root …`) leaves
        // `root` as the target, which is not an allowed command, so the command
        // refuses: the failure direction is closed.
        var argvPerSegment: [[String]] = []
        for segment in segments {
            var cursor = 0
            while cursor < segment.count,
                  wrapperCommands.contains(segment[cursor])
                    || matches(segment[cursor], "^[a-z_][a-z0-9_]*=") {
                cursor += 1
                while cursor < segment.count && segment[cursor].hasPrefix("-") { cursor += 1 }
            }
            argvPerSegment.append(cursor < segment.count ? Array(segment[cursor...]) : [])
        }

        // Every word the command will run, in order, with `programs[i]` being the
        // word sub-command `i` runs — after any wrapper, and the word the allowlist
        // decides on. Keeping both means a banned word is caught wherever it sits:
        // as a program (`rm x`), as the program of a later sub-command (`ls && rm x`
        // — `rm` is that sub-command's program), or as an operand (`which rm`).
        var programs: [String] = []
        var allWords: [String] = []
        for argv in argvPerSegment {
            if let program = argv.first { programs.append(program) }
            allWords.append(contentsOf: argv)
        }
        let firstWord = programs.first

        // --- 2. The ban list. A hit refuses the whole command, in any position.
        for (pattern, why) in dangerousWords {
            for candidate in allWords where hasWord(candidate, pattern) {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "`\(candidate)` appears in the command and \(why)",
                    rule: "banned-word:\(pattern)",
                    words: allWords,
                    firstWord: firstWord
                )
            }
        }
        // The constructs: redirects (`>`, `>>`, `<`, `<<`, and an operand glued to
        // one — `2>f`, `>>out`), chaining (`;`, `&&`, `||`, `&`, `|`) and
        // substitution (`$(…)`, backticks, a bare bracket). None of them is allowed
        // in plan mode, because a chain hides everything after its first command
        // from this check.
        for candidate in allWords {
            // A redirect is a word built from `>` or `<` — bare (`>`, `>>`), or an
            // operand glued to one (`2>f`, `>>out`). Quoted text is a single word
            // and is NOT a redirect: the scan keeps `a > b` inside the quotes, so
            // `echo 'a > b'` never produces the bare word `>` and is allowed.
            if candidate.contains(">") || candidate.contains("<") {
                let bare = candidate == ">" || candidate == ">>"
                    || candidate == "<" || candidate == "<<"
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "the command redirects with `\(candidate)`, which writes a file or "
                        + "reads beyond the named inputs",
                    rule: bare ? "redirect" : "redirect-attached",
                    words: allWords,
                    firstWord: firstWord
                )
            }
            if candidate == ";" || candidate == "&&" || candidate == "||"
                || candidate == "&" || candidate == "|" {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "it chains or pipes commands with `\(candidate)`, so only the first "
                        + "command is visible to this check",
                    rule: "chain:\(candidate)",
                    words: allWords,
                    firstWord: firstWord
                )
            }
            if candidate == "(" || candidate == ")" || candidate.contains("$(") || candidate.contains("`") {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "it substitutes or groups commands (`$(…)`, backticks, or a "
                        + "sub-shell), so the command runs something this check cannot see",
                    rule: "substitution",
                    words: allWords,
                    firstWord: firstWord
                )
            }
        }
        for candidate in allWords {
            for flag in dangerousFlags where candidate == flag {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "it passes `\(flag)`, which makes a read-only tool write or re-run",
                    rule: "banned-flag:\(flag)",
                    words: allWords,
                    firstWord: firstWord
                )
            }
        }

        // --- 3. The allowlist. Every sub-command must run an allowed program;
        // anything else refuses, which is the branch that keeps a command nobody
        // anticipated out rather than in.
        guard let first = firstWord else {
            return ShellCommandVerdict(
                allowed: false,
                reason: "the command is empty, so nothing can be checked",
                rule: "empty",
                words: allWords,
                firstWord: nil
            )
        }

        for head in programs {
            guard allowedCommands.contains(head) else {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "`\(head.isEmpty ? "the command" : head)` is not one of the read-only "
                        + "commands plan mode allows (\(readOnlyCommandSummary))",
                    rule: "not-allowed-head",
                    words: allWords,
                    firstWord: first
                )
            }
        }

        // --- 4. The closed exception to an allowed word, for `git` only. The
        // sub-command is resolved first — `git branch` reads, `git branch -D` does
        // not — and then the operands decide:
        //
        //   * `argv[1]` in `gitReadOnlySubcommands` is accepted; in
        //     `gitMutatingWords` it is refused by name; in neither, it is refused as
        //     an unknown sub-command (which is also how bare `git` fails);
        //   * an operand from `gitMutatingWords` is refused, because the read-only
        //     sub-commands have writing forms that name their verb as one
        //     (`git remote add …`, `git tag -d …`);
        //   * any other non-flag operand is refused, because the read-only forms
        //     take none (`git diff HEAD~1`).
        for argv in argvPerSegment where argv.first == "git" {
            let arguments = Array(argv.dropFirst())
            guard let subcommand = arguments.first else {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "`git` was called with no sub-command, so there is nothing to check",
                    rule: "git-subcommand",
                    words: allWords,
                    firstWord: first
                )
            }
            // The read-only list is consulted first, because `branch` and `remote`
            // are in both lists on purpose: bare `git branch` reads, `git branch -D`
            // writes, and it is the operand that decides. A sub-command that is in
            // neither list is refused as unknown.
            guard gitReadOnlySubcommands.contains(subcommand) else {
                if gitMutatingWords.contains(subcommand) {
                    return ShellCommandVerdict(
                        allowed: false,
                        reason: "`git \(subcommand)` changes the repository, and only read-only "
                            + "git sub-commands are allowed while planning",
                        rule: "git-mutating:\(subcommand)",
                        words: allWords,
                        firstWord: first
                    )
                }
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "`git` sub-command `\(subcommand)` is not one of the read-only "
                        + "sub-commands allowed while planning "
                        + "(\(gitReadOnlySubcommands.joined(separator: ", ")))",
                    rule: "git-subcommand",
                    words: allWords,
                    firstWord: first
                )
            }
            // The sub-command is a known read-only form here, so the mutating list
            // is applied to the operands only — `git branch -a` and `git remote -v`
            // are reads; `git remote add …` and `git tag -d …` are not.
            for argument in arguments.dropFirst() {
                for mutating in gitMutatingWords where argument == mutating {
                    return ShellCommandVerdict(
                        allowed: false,
                        reason: "`git \(subcommand) \(argument)` changes the repository, and only "
                            + "read-only git sub-commands are allowed while planning",
                        rule: "git-mutating:\(argument)",
                        words: allWords,
                        firstWord: first
                    )
                }
            }
            for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
                return ShellCommandVerdict(
                    allowed: false,
                    reason: "`git \(subcommand)` was given the operand `\(argument)`, and the "
                        + "read-only git forms take none — revise the plan with the read-only form",
                    rule: "git-operand",
                    words: allWords,
                    firstWord: first
                )
            }
        }

        // --- 6. Allowed. An allowed `git` keeps the sub-command it matched so the
        // rule reads back as `git-read-only:log` rather than a bare yes.
        let gitSubcommand = argvPerSegment
            .first { $0.first == "git" }?
            .dropFirst()
            .first
        let rule = gitSubcommand.map { "git-read-only:\($0)" } ?? "allowed-head:\(first)"
        return ShellCommandVerdict(
            allowed: true, reason: "", rule: rule, words: allWords, firstWord: first
        )
    }

    static let policyText = """
    You are in plan mode. Stay in plan mode until the user approves your plan through exit_plan_mode or switches the session mode. Imperative language to implement changes means plan the implementation, not execute it. A user's conversational agreement — including an answer confirming something you asked — approves nothing and does not end plan mode; fold the confirmed decision into the plan and submit it through exit_plan_mode.

    Explore first. Use non-mutating reads, searches, static analysis, and checks to ground the plan in the actual repository. Do not edit or write files, change configuration, run formatters or code generation that rewrites tracked files, commit, or otherwise carry out the plan. Prefer existing functions and patterns over new machinery.

    The tool catalog stays the same across modes for request-cache stability. These plan-mode rules override any later tool description or guidance that suggests using mutation tools; those tools remain listed only to keep the request shape stable. Do not use todo_write to track this planning phase: it tracks implementation after an approved plan, while the plan itself belongs in exit_plan_mode.

    Resolve discoverable facts by inspection. Ask the user only for user-owned choices or material ambiguity that inspection cannot answer. Do not ask the user where code lives or how current behavior works when you can find out.

    Make the plan decision-complete: state the goal and success criteria; group implementation changes by subsystem; identify public API, schema, and data-flow changes; cover edge cases, failure modes, tests, acceptance criteria, and explicit assumptions. Keep it concise enough to review but detailed enough that another engineer can implement it without making design decisions.

    When ready, call exit_plan_mode with the complete plan markdown, starting with a # title. Make exit_plan_mode the only and final tool call in that assistant response: it presents the plan for approval, and implementation begins only in a later step after approval. Do not paste the final plan as a plain reply or ask "should I proceed?" through prose. If review rejects it, incorporate the feedback and present again. If the review channel is unavailable or aborted, stay in plan mode and ask the user to switch modes manually; do not proceed with implementation.

    In this app, plan mode still reads, because a plan cannot be made without the facts. Available while plan mode is on: web_search for information that is not in this repository; file_read, memory_get, read_image and browser_use for material on the device or on a page; and shell_execute for \(readOnlyCommandSentence). A read-only command is checked before it runs and refused when it is not on that list, or when it redirects or writes (>, >>), chains or pipes (&&, ;, |), substitutes a command ($(…), backticks), or uses a mutating git sub-command (git add, commit, push, checkout, reset, clean). A refusal names the rule it hit: treat it as a signal to plan a different inspection, never as something to work around. Still off limits, and refused before running: file_write, file_edit, memory_write and todo_write. When the plan is ready, exit_plan_mode is the only and final tool call in that response.
    """

    // MARK: - Transition

    public static func enter(reason: String? = nil) -> String {
        DSHTodoStore.shared.setPlanMode(true)
        if let reason, !reason.isEmpty {
            return "Plan mode on. Work out the plan for: \(reason)"
        }
        return "Plan mode on. Use /plan off to leave."
    }

    public static func leave() -> String {
        DSHTodoStore.shared.setPlanMode(false)
        return "Plan mode off."
    }

    /// Handle an `exit_plan_mode` call.
    ///
    /// Suspends on the user's decision. The plan is presented through
    /// `DSHPlanApproval` and this call does not return until the user approves,
    /// asks to keep planning, dismisses the review to speak, cancels the turn,
    /// or the review hits its deadline.
    ///
    /// - Returns: the model-facing result, or the reason the call was rejected.
    ///   Every non-approving path is a failure on purpose: "the plan was not
    ///   approved" has to read as a rejection to the model, because a success
    ///   result is what tells it to start implementing.
    public static func exit(plan rawPlan: Any?) async -> DSHToolOutcome {
        guard DSHTodoStore.shared.planModeActive else {
            return .failed("exit_plan_mode is only available in plan mode.")
        }
        guard let plan = rawPlan as? String else {
            return .failed("exit_plan_mode requires a `plan` string.")
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        // DSH rejects a plan that does not open with a level-1 heading: the
        // heading is what the transcript card and the review sheet title
        // themselves from, and a plan without one reads as a stray paragraph.
        guard trimmed.hasPrefix("# "),
              trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failed(
                "exit_plan_mode requires a non-empty markdown plan starting with a # heading that names it."
            )
        }

        let decision = await DSHPlanApproval.shared.review(
            plan: trimmed,
            title: firstHeading(trimmed) ?? "Plan"
        )

        switch decision {
        case .approve:
            DSHTodoStore.shared.setPlanMode(false)
            // DSH's own success text, verbatim (`plan-mode/src/index.ts`, the
            // tool's output render). Deliberately unchanged: the model is told
            // to carry on from its next step, and that phrasing is what its plan
            // policy referred to.
            return .ok("Plan approved — plan mode exited; carry out the plan starting with your next step.")

        case .keepPlanning(let feedback):
            // DSH's two texts, verbatim: unlike a rejection from prose, "keep
            // planning" is an instruction to revise and resubmit, and the
            // feedback is the revision brief.
            return .failed(feedback.isEmpty
                ? "The user chose to keep planning; revise the plan and present it again."
                : "The user chose to keep planning; their feedback: \(feedback)")

        case .dismissed:
            return .failed(
                "The user dismissed the plan review to speak instead; "
                + "stay in plan mode, stop here, and wait for their message."
            )

        case .cancelled:
            return .failed(
                "The plan review was cancelled before the user answered; "
                + "stay in plan mode and present the plan again when they ask."
            )

        case .timedOut:
            // Our own text: DSH has no deadline, because its channel assumes an
            // interactive session. The model must not treat "no answer" as an
            // approval, so it is told plainly and sent back to the mode.
            return .failed(
                "The plan review was not answered within \(Int(DSHPlanApproval.reviewTimeout / 60)) minutes; "
                + "stay in plan mode and present the plan again when the user is ready."
            )

        case .busy:
            return .failed(
                "A plan review is already open and waiting for the user; "
                + "do not call exit_plan_mode again until it is answered."
            )
        }
    }

    /// The plan's first level-1 heading, for the review sheet's title.
    ///
    /// Ported from DSH's `firstHeading(args.plan) ?? 'Plan'`: the first
    /// non-empty line, with `# ` stripped. Returns nil for anything that is not
    /// a level-1 heading, and the caller falls back to "Plan".
    static func firstHeading(_ markdown: String) -> String? {
        let firstNonEmpty = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = firstNonEmpty?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard line.hasPrefix("# ") else { return nil }
        let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
