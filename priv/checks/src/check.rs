//! What a check is, and what it is given.
//!
//! A check is a rule the repository must follow. It is given the `State`
//! of the code, every file and every file the branch changed, and its own
//! `Config`, and returns `Violation`s: this file, this line, breaks the
//! rule. It does not decide what a violation means, and it does not print.
//! The config says whether a violation is an error or a warning, and the
//! runner prints.
//!
//! Most checks follow one shape, with a helper for each step:
//!
//! 1. pick the files, `state.files(config.scope())`, and keep the ones the
//!    check applies to, `.with_extension(&["ex", "heex"])`;
//! 2. a `fast` pass, a cheap test that must never miss a real problem;
//! 3. a `slow` pass over the files the fast pass kept, which does the
//!    careful work and returns the violations;
//! 4. `state.in_scope(config.scope(), violations)`, which drops violations
//!    on lines the branch did not change when the scope is `changed`.
//!
//! A check about the branch rather than about a file, such as "a protected
//! file must be the only change", reads `state.changed()` instead.

// This module is the API for the project's own checks too, so not every
// item is used by the built-in ones.
#![allow(dead_code)]

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};

use rayon::prelude::*;

/// A file in the project. The contents are read from disk the first time
/// a check asks for them, and shared by every check after that.
pub struct File {
    pub path: PathBuf,
    contents: OnceLock<String>,
}

impl File {
    /// A file that is read when first asked for.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            contents: OnceLock::new(),
        }
    }

    /// A file with these contents, never read from disk. For tests.
    pub fn with_contents(path: impl Into<PathBuf>, contents: impl Into<String>) -> Self {
        let file = Self::new(path);
        let _ = file.contents.set(contents.into());
        file
    }

    /// The contents. A file that cannot be read as text is reported once
    /// on stderr and treated as empty, so a check sees nothing in it.
    pub fn contents(&self) -> &str {
        self.contents
            .get_or_init(|| match fs::read_to_string(&self.path) {
                Ok(contents) => contents,
                Err(error) => {
                    eprintln!("skipping {}: {error}", self.path.display());
                    String::new()
                }
            })
    }

    /// The 1-based line number of the byte at `offset`.
    pub fn line_of(&self, offset: usize) -> usize {
        self.contents()[..offset].matches('\n').count() + 1
    }

    /// Whether the file name ends in one of `extensions`, given without
    /// the dot, so `"heex"` matches `home.html.heex`.
    pub fn has_extension(&self, extensions: &[&str]) -> bool {
        self.path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext))
    }
}

/// Keeps only some of a list of files. Implemented for `Vec<&File>`, which
/// is what `State::files` returns.
pub trait Files<'a>: Sized {
    /// The files whose name ends in one of `extensions`, given without the
    /// dot.
    fn with_extension(self, extensions: &[&str]) -> Self;
}

impl<'a> Files<'a> for Vec<&'a File> {
    fn with_extension(self, extensions: &[&str]) -> Self {
        self.into_iter()
            .filter(|file| file.has_extension(extensions))
            .collect()
    }
}

/// Which files a check looks at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// Every file in the project.
    All,
    /// The files the branch changed, and only the lines it changed.
    Changed,
}

impl FromStr for Scope {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "all" => Ok(Scope::All),
            "changed" => Ok(Scope::Changed),
            other => Err(format!("scope must be all or changed, got {other}")),
        }
    }
}

/// What a violation means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    /// Fails the run.
    Error,
    /// Printed, and the run passes.
    Warning,
}

impl FromStr for Level {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "error" => Ok(Level::Error),
            "warning" => Ok(Level::Warning),
            other => Err(format!("level must be error or warning, got {other}")),
        }
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Level::Error => "error",
            Level::Warning => "warning",
        })
    }
}

/// The lines the branch changed in one file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Lines {
    /// Every line, for a file the branch added.
    All,
    /// These 1-based lines. Empty for a file that only lost lines.
    Only(Vec<Range<usize>>),
}

impl Lines {
    pub fn contains(&self, line: usize) -> bool {
        match self {
            Lines::All => true,
            Lines::Only(ranges) => ranges.iter().any(|range| range.contains(&line)),
        }
    }
}

/// A file the branch changed, with the lines it changed. A deleted file
/// is listed with no lines and is not among the project's files.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChangedFile {
    pub path: PathBuf,
    pub lines: Lines,
}

/// The state of the code, gathered once by the runner and shared by every
/// check: every file in the project, and every file the branch changed
/// compared with `base`, with the lines it changed.
pub struct State {
    /// The git ref the branch was compared with.
    pub base: String,
    all: Vec<File>,
    changed: Vec<ChangedFile>,
    changed_index: HashMap<PathBuf, usize>,
}

impl State {
    pub fn new(base: impl Into<String>, all: Vec<File>, changed: Vec<ChangedFile>) -> Self {
        let changed_index = changed
            .iter()
            .enumerate()
            .map(|(index, file)| (file.path.clone(), index))
            .collect();
        Self {
            base: base.into(),
            all,
            changed,
            changed_index,
        }
    }

    /// The files a check with this scope looks at: every file, or the ones
    /// the branch changed and still exist.
    pub fn files(&self, scope: Scope) -> Vec<&File> {
        match scope {
            Scope::All => self.all.iter().collect(),
            Scope::Changed => self
                .all
                .iter()
                .filter(|file| self.changed_index.contains_key(&file.path))
                .collect(),
        }
    }

    /// Every file in the project.
    pub fn all(&self) -> &[File] {
        &self.all
    }

    /// Every file the branch changed, deleted ones included, with the lines
    /// it changed. Sorted by path.
    pub fn changed(&self) -> &[ChangedFile] {
        &self.changed
    }

    /// The lines the branch changed in `path`, or `None` when it did not
    /// touch the file.
    pub fn changed_lines(&self, path: &Path) -> Option<&Lines> {
        self.changed_index
            .get(path)
            .map(|index| &self.changed[*index].lines)
    }

    /// The violations that count under `scope`. With `Scope::All`, all of
    /// them. With `Scope::Changed`, one on a line must be on a changed line,
    /// one about a file must be about a changed file, and one about the
    /// whole run always counts.
    pub fn in_scope(&self, scope: Scope, violations: Vec<Violation>) -> Vec<Violation> {
        match scope {
            Scope::All => violations,
            Scope::Changed => violations
                .into_iter()
                .filter(|violation| match (&violation.path, violation.line) {
                    (Some(path), Some(line)) => self
                        .changed_lines(path)
                        .is_some_and(|lines| lines.contains(line)),
                    (Some(path), None) => self.changed_index.contains_key(path),
                    (None, _) => true,
                })
                .collect(),
        }
    }
}

/// One fact a check found. `path` is empty for a fact about the whole run,
/// `line` for a fact about a whole file.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Violation {
    pub path: Option<PathBuf>,
    pub line: Option<usize>,
    pub message: String,
}

impl Violation {
    /// On a line of the file the `slow` pass is looking at, which fills in
    /// the path.
    pub fn at(line: usize, message: impl Into<String>) -> Self {
        Self {
            path: None,
            line: Some(line),
            message: message.into(),
        }
    }

    /// On a line of a named file.
    pub fn in_file(path: impl Into<PathBuf>, line: usize, message: impl Into<String>) -> Self {
        Self {
            path: Some(path.into()),
            line: Some(line),
            message: message.into(),
        }
    }

    /// About a whole file.
    pub fn file(path: impl Into<PathBuf>, message: impl Into<String>) -> Self {
        Self {
            path: Some(path.into()),
            line: None,
            message: message.into(),
        }
    }

    /// About the whole run.
    pub fn run(message: impl Into<String>) -> Self {
        Self {
            path: None,
            line: None,
            message: message.into(),
        }
    }

    /// `path:line: message`, `path: message` or `message`.
    pub fn location(&self) -> String {
        match (&self.path, self.line) {
            (Some(path), Some(line)) => format!("{}:{line}: ", path.display()),
            (Some(path), None) => format!("{}: ", path.display()),
            (None, _) => String::new(),
        }
    }
}

/// Where the runner prints, and how much.
#[derive(Clone, Copy, Debug, Default)]
pub struct Output {
    /// Print every stage as it happens, not only the result.
    pub verbose: bool,
    /// Print nothing. For tests.
    pub quiet: bool,
}

/// One check's config for one run: its name, what a violation means, which
/// files it looks at, and its own keys from `--set NAME.KEY=VALUE`, with
/// the name removed. Order is kept, and a key may repeat.
pub struct Config {
    name: &'static str,
    level: Level,
    scope: Scope,
    entries: Vec<(String, String)>,
    output: Output,
    /// Violations already printed in their final form while the check ran,
    /// so the runner does not print them again.
    printed: Mutex<HashSet<Violation>>,
}

impl Config {
    pub fn new(
        name: &'static str,
        level: Level,
        scope: Scope,
        entries: Vec<(String, String)>,
        output: Output,
    ) -> Self {
        Self {
            name,
            level,
            scope,
            entries,
            output,
            printed: Mutex::new(HashSet::new()),
        }
    }

    pub fn name(&self) -> &'static str {
        self.name
    }

    pub fn level(&self) -> Level {
        self.level
    }

    pub fn scope(&self) -> Scope {
        self.scope
    }

    pub fn verbose(&self) -> bool {
        self.output.verbose
    }

    /// The last value given for `key`, so a later one overrides an earlier
    /// one.
    pub fn one(&self, key: &str) -> Option<&str> {
        self.entries
            .iter()
            .rev()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// Every value given for `key`, in order.
    pub fn many(&self, key: &str) -> Vec<&str> {
        self.entries
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    /// Every `(rest of key, value)` whose key starts with `prefix.`, in
    /// order. `under("groups")` on `groups.agents=AGENTS.md` yields
    /// `("agents", "AGENTS.md")`.
    pub fn under(&self, prefix: &str) -> Vec<(&str, &str)> {
        let prefix = format!("{prefix}.");
        self.entries
            .iter()
            .filter_map(|(k, v)| {
                k.strip_prefix(prefix.as_str())
                    .map(|rest| (rest, v.as_str()))
            })
            .collect()
    }

    /// Whether `key` is in `accepted`, where an entry ending in `.*` accepts
    /// any one more segment.
    pub fn accepts(accepted: &[&str], key: &str) -> bool {
        accepted
            .iter()
            .any(|pattern| match pattern.strip_suffix(".*") {
                Some(prefix) => key
                    .strip_prefix(prefix)
                    .and_then(|rest| rest.strip_prefix('.'))
                    .is_some_and(|rest| !rest.is_empty() && !rest.contains('.')),
                None => *pattern == key,
            })
    }

    /// `location message [name, label]`.
    fn line(&self, location: &str, message: &str, label: &str) {
        if !self.output.quiet {
            println!("{location}{message} [{}, {label}]", self.name);
        }
    }

    /// Prints a stage of the check, labelled with the stage.
    pub(crate) fn stage(&self, stage: &str, violation: &Violation) {
        self.line(&violation.location(), &violation.message, stage);
    }

    /// Prints a violation in its final form and remembers it.
    pub(crate) fn report(&self, violation: &Violation) {
        self.line(
            &violation.location(),
            &violation.message,
            &self.level.to_string(),
        );
        self.printed.lock().unwrap().insert(violation.clone());
    }

    /// The violations not yet printed in their final form.
    pub(crate) fn unreported<'a>(&self, violations: &'a [Violation]) -> Vec<&'a Violation> {
        let printed = self.printed.lock().unwrap();
        violations
            .iter()
            .filter(|violation| !printed.contains(violation))
            .collect()
    }
}

/// The fast pass: keeps the files `keep` says yes to, in parallel. It is a
/// cheap test that must never miss a real problem. Over-reporting is fine,
/// since the slow pass looks again.
pub fn fast<'a>(
    config: &Config,
    files: Vec<&'a File>,
    keep: impl Fn(&File) -> bool + Sync,
) -> Vec<&'a File> {
    let mut kept: Vec<&File> = files.into_par_iter().filter(|file| keep(file)).collect();
    kept.sort_by(|a, b| a.path.cmp(&b.path));

    if config.verbose() {
        for file in &kept {
            config.stage(
                "fast",
                &Violation::file(&file.path, "kept by the fast pass"),
            );
        }
    }
    kept
}

/// The slow pass: the careful work on the files the fast pass kept, in
/// parallel. `find` returns the violations in one file; a violation made
/// with `Violation::at` gets the file's path filled in. With `Scope::All`
/// each file's violations print as soon as it is done, so a long run shows
/// progress. With `Scope::Changed` they wait for `State::in_scope`.
pub fn slow(
    config: &Config,
    files: Vec<&File>,
    find: impl Fn(&File) -> Vec<Violation> + Sync,
) -> Vec<Violation> {
    files
        .into_par_iter()
        .flat_map_iter(|file| {
            let mut found = find(file);
            for violation in &mut found {
                if violation.path.is_none() {
                    violation.path = Some(file.path.clone());
                }
            }
            for violation in &found {
                if config.verbose() {
                    config.stage("slow", violation);
                } else if config.scope() == Scope::All {
                    config.report(violation);
                }
            }
            found
        })
        .collect()
}

/// A set of path patterns from a config key, for checks about which paths
/// changed. A pattern matches the whole path from the project root. `*`
/// does not cross a `/`, `**` does. An invalid pattern is an error naming
/// the key. No patterns at all is an error too, so a check never quietly
/// matches nothing.
pub fn glob_set(key: &str, patterns: &[&str]) -> Result<globset::GlobSet, String> {
    if patterns.is_empty() {
        return Err(format!("set {key} to at least one path pattern"));
    }
    let mut builder = globset::GlobSetBuilder::new();
    for pattern in patterns {
        let glob = globset::GlobBuilder::new(pattern)
            .literal_separator(true)
            .build()
            .map_err(|error| {
                format!("{key}: {pattern} is not a valid pattern: {}", error.kind())
            })?;
        builder.add(glob);
    }
    builder.build().map_err(|error| error.to_string())
}

/// A rule the repository must follow. Every file in `priv/checks` exports
/// one as `CHECK`.
pub trait Check: Sync {
    /// The file name without `.rs`. It is how the config refers to the
    /// check and is shown next to each violation. A generated test fails
    /// the build when the two differ.
    fn name(&self) -> &'static str;

    /// The config keys this check accepts. A key ending in `.*` accepts any
    /// single segment there, so `groups.*` accepts `groups.agents`. A key
    /// outside this list stops the run before any check runs.
    fn config_keys(&self) -> &'static [&'static str] {
        &[]
    }

    /// Runs once, before anything runs or prints. A check that needs more
    /// than the files in front of it, such as a list of names read from one
    /// module, reads it here and keeps it. An `Err` names what is wrong
    /// with the config and stops the run with exit code 2.
    fn prepare(&self, _config: &Config) -> Result<(), String> {
        Ok(())
    }

    /// Finds the violations. An `Err` stops the run with exit code 2.
    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String>;
}

/// Helpers for unit testing a check with inline snippets. A `State` is
/// built from files, a `Config` from key and value pairs, and `run` gives
/// each violation as one `path:line: message` string.
#[cfg(test)]
pub mod testing {
    use super::*;

    /// Builds a `State` file by file.
    #[derive(Default)]
    pub struct StateBuilder {
        all: Vec<File>,
        changed: Vec<ChangedFile>,
    }

    pub fn state() -> StateBuilder {
        StateBuilder::default()
    }

    impl StateBuilder {
        /// A file the branch did not touch.
        pub fn file(mut self, path: &str, contents: &str) -> Self {
            self.all.push(File::with_contents(path, contents));
            self
        }

        /// A file the branch changed on these 1-based lines.
        pub fn changed(mut self, path: &str, contents: &str, lines: &[usize]) -> Self {
            self.all.push(File::with_contents(path, contents));
            self.changed.push(ChangedFile {
                path: PathBuf::from(path),
                lines: Lines::Only(lines.iter().map(|line| *line..line + 1).collect()),
            });
            self
        }

        /// A file the branch added, so every line is changed.
        pub fn added(mut self, path: &str, contents: &str) -> Self {
            self.all.push(File::with_contents(path, contents));
            self.changed.push(ChangedFile {
                path: PathBuf::from(path),
                lines: Lines::All,
            });
            self
        }

        /// A file the branch deleted.
        pub fn deleted(mut self, path: &str) -> Self {
            self.changed.push(ChangedFile {
                path: PathBuf::from(path),
                lines: Lines::Only(Vec::new()),
            });
            self
        }

        pub fn build(mut self) -> State {
            self.all.sort_by(|a, b| a.path.cmp(&b.path));
            self.changed.sort_by(|a, b| a.path.cmp(&b.path));
            State::new("main", self.all, self.changed)
        }
    }

    /// A config for `check` with these keys, as an error over all files,
    /// printing nothing.
    pub fn config(check: &dyn Check, entries: &[(&str, &str)]) -> Config {
        scoped(check, Scope::All, entries)
    }

    /// The same with a scope.
    pub fn scoped(check: &dyn Check, scope: Scope, entries: &[(&str, &str)]) -> Config {
        Config::new(
            check.name(),
            Level::Error,
            scope,
            entries
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            Output {
                verbose: false,
                quiet: true,
            },
        )
    }

    /// Prepares and runs the check, and returns each violation as
    /// `path:line: message`, sorted. Panics on an error.
    pub fn run(check: &dyn Check, state: &State, config: &Config) -> Vec<String> {
        check.prepare(config).expect("prepare succeeds");
        let mut violations = check.run(state, config).expect("run succeeds");
        violations.sort_by(|a, b| a.path.cmp(&b.path).then(a.line.cmp(&b.line)));
        violations
            .iter()
            .map(|violation| format!("{}{}", violation.location(), violation.message))
            .collect()
    }

    /// The error that preparing or running the check gives.
    pub fn error(check: &dyn Check, state: &State, config: &Config) -> String {
        check
            .prepare(config)
            .and_then(|()| check.run(state, config).map(|_| ()))
            .expect_err("prepare or run fails")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use testing::state;

    struct Nothing;

    impl Check for Nothing {
        fn name(&self) -> &'static str {
            "nothing"
        }

        fn run(&self, _state: &State, _config: &Config) -> Result<Vec<Violation>, String> {
            Ok(Vec::new())
        }
    }

    #[test]
    fn accepts_exact_keys_and_one_segment_wildcards() {
        let accepted = &["paths", "groups.*"];
        assert!(Config::accepts(accepted, "paths"));
        assert!(Config::accepts(accepted, "groups.agents"));
        assert!(!Config::accepts(accepted, "groups"));
        assert!(!Config::accepts(accepted, "groups.a.b"));
        assert!(!Config::accepts(accepted, "scope"));
    }

    #[test]
    fn later_values_win_for_one_and_all_are_kept_for_many_and_under() {
        let config = testing::config(
            &Nothing,
            &[
                ("default", "high"),
                ("groups.agents", "AGENTS.md"),
                ("paths", "a"),
                ("default", "standard"),
                ("paths", "b"),
                ("groups.lint", ".credo.exs"),
            ],
        );
        assert_eq!(config.one("default"), Some("standard"));
        assert_eq!(config.many("paths"), vec!["a", "b"]);
        assert_eq!(config.one("missing"), None);
        assert_eq!(
            config.under("groups"),
            vec![("agents", "AGENTS.md"), ("lint", ".credo.exs")]
        );
    }

    #[test]
    fn files_by_scope_and_extension() {
        let state = state()
            .file("lib/a.ex", "")
            .changed("lib/b.ex", "", &[1])
            .added("lib/c.heex", "")
            .deleted("lib/d.ex")
            .build();

        let names = |files: Vec<&File>| {
            files
                .iter()
                .map(|f| f.path.display().to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            names(state.files(Scope::All)),
            vec!["lib/a.ex", "lib/b.ex", "lib/c.heex"]
        );
        assert_eq!(
            names(state.files(Scope::Changed)),
            vec!["lib/b.ex", "lib/c.heex"]
        );
        assert_eq!(
            names(state.files(Scope::All).with_extension(&["ex"])),
            vec!["lib/a.ex", "lib/b.ex"]
        );
        assert_eq!(state.changed().len(), 3);
    }

    #[test]
    fn in_scope_keeps_changed_lines_changed_files_and_the_whole_run() {
        let state = state()
            .file("a.ex", "")
            .changed("b.ex", "", &[2, 3])
            .added("c.ex", "")
            .deleted("d.ex")
            .build();
        let violations = vec![
            Violation::in_file("a.ex", 1, "untouched file"),
            Violation::in_file("b.ex", 1, "untouched line"),
            Violation::in_file("b.ex", 2, "changed line"),
            Violation::in_file("c.ex", 40, "added file"),
            Violation::file("a.ex", "about an untouched file"),
            Violation::file("d.ex", "about a deleted file"),
            Violation::run("about the run"),
        ];

        let all = state.in_scope(Scope::All, violations.clone());
        assert_eq!(all.len(), 7);

        let changed = state.in_scope(Scope::Changed, violations);
        let messages: Vec<&str> = changed.iter().map(|v| v.message.as_str()).collect();
        assert_eq!(
            messages,
            vec![
                "changed line",
                "added file",
                "about a deleted file",
                "about the run"
            ]
        );
    }

    #[test]
    fn slow_fills_in_the_path_and_fast_keeps_only_what_passes() {
        let state = state().file("a.ex", "x\ny\n").file("b.ex", "y\n").build();
        let config = testing::config(&Nothing, &[]);

        let kept = fast(&config, state.files(Scope::All), |file| {
            file.contents().contains('x')
        });
        assert_eq!(kept.len(), 1);

        let found = slow(&config, kept, |file| {
            vec![Violation::at(file.line_of(0), "has an x")]
        });
        assert_eq!(found, vec![Violation::in_file("a.ex", 1, "has an x")]);
        assert_eq!(config.unreported(&found).len(), 0, "reported as it went");
    }

    #[test]
    fn a_file_that_cannot_be_read_is_empty() {
        let file = File::new("/no/such/file.ex");
        assert_eq!(file.contents(), "");
        assert!(file.has_extension(&["ex"]));
        assert!(!file.has_extension(&["exs"]));
    }
}
