//! Component tags: a template must use the component for any tag the
//! components modules define, `<.button>` instead of `<button>`.
//!
//! The list of tags is read from the modules themselves, once, in
//! `prepare`. Every public `def` whose name could be an HTML tag counts:
//! lower case letters and digits, as in `p`, `h1`, `button`, `input`,
//! `table`. `defp` does not count, and neither does a name with an
//! underscore. The module files themselves are skipped, since their
//! components render the raw tags.
//!
//! Fast pass: one regular expression for all the tags, built once, over the
//! whole file. Slow pass: the same expression over only the templates in
//! the file, which is the whole of a `.heex` file and the body of every
//! `~H` sigil in an `.ex` file, so a mention in a doc string or a comment
//! is not a violation.
//!
//! One config key, `paths`, given once per module: the components modules.
//! A design system that spans several files lists each. When not set, the
//! one file called `core_components.ex` under `lib`.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, OnceLock};

use regex::Regex;
use walkdir::WalkDir;

use crate::check::{fast, slow, Check, Config, File, Files, State, Violation};

pub struct CoreComponentTags {
    /// Set by `prepare`, read by `run`.
    components: OnceLock<Components>,
}

static CORE_COMPONENT_TAGS: CoreComponentTags = CoreComponentTags::new();

/// The check this file contributes. Every file in `src/checks/` exports one.
pub const CHECK: &dyn Check = &CORE_COMPONENT_TAGS;

/// The file `prepare` looks for under `lib` when `paths` is not set.
const DEFAULT_FILE: &str = "core_components.ex";

/// `defmodule Name do`, for the message.
static MODULE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^[ \t]*defmodule[ \t]+([A-Z][A-Za-z0-9_.]*)").unwrap());

/// `def name(`, where the name could be an HTML tag.
static DEF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^[ \t]*def[ \t]+([a-z][a-z0-9]*)[ \t]*\(").unwrap());

/// One components module, as `prepare` read it.
#[derive(Debug)]
struct Module {
    /// The module name, such as `ExampleWeb.CoreComponents`.
    name: String,
    /// Where the module is, as a canonical path, so the file can be skipped
    /// however it was named.
    path: PathBuf,
    /// The tags it defines, sorted, without repeats.
    tags: Vec<String>,
}

/// Every components module together.
#[derive(Debug)]
struct Components {
    /// Where the modules are, as canonical paths.
    paths: Vec<PathBuf>,
    /// Each tag and the name of the module that defines it.
    modules: HashMap<String, String>,
    /// `<` then one of the tags then whitespace, `/`, `>` or the end of the
    /// file. Group 1 is the tag. `</p>` and `<.p>` do not match.
    raw_tag: Regex,
}

impl CoreComponentTags {
    const fn new() -> Self {
        Self {
            components: OnceLock::new(),
        }
    }

    fn components(&self) -> &Components {
        self.components
            .get()
            .expect("core_component_tags runs prepare before run")
    }
}

impl Check for CoreComponentTags {
    fn name(&self) -> &'static str {
        "core_component_tags"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["paths"]
    }

    fn prepare(&self, config: &Config) -> Result<(), String> {
        // A second prepare, as in tests, keeps the first result.
        if self.components.get().is_some() {
            return Ok(());
        }

        let paths = config.many("paths");
        let paths: Vec<PathBuf> = if paths.is_empty() {
            vec![find_module(Path::new("lib"))?]
        } else {
            paths.into_iter().map(PathBuf::from).collect()
        };

        let modules = paths
            .iter()
            .map(|path| Module::read(path))
            .collect::<Result<Vec<_>, _>>()?;
        let components = Components::new(modules)?;

        let _ = self.components.set(components);
        Ok(())
    }

    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
        let components = self.components();

        let files: Vec<&File> = state
            .files(config.scope())
            .with_extension(&["ex", "heex"])
            .into_iter()
            .filter(|file| !components.is_module(file))
            .collect();

        let suspects = fast(config, files, |file| {
            components.raw_tag.is_match(file.contents())
        });

        let violations = slow(config, suspects, |file| {
            let contents = file.contents();
            template_ranges(file)
                .into_iter()
                .flat_map(|(start, end)| {
                    components
                        .raw_tags(&contents[start..end])
                        .map(move |(offset, tag)| (start + offset, tag))
                })
                .map(|(offset, tag)| Violation::at(file.line_of(offset), components.message(tag)))
                .collect()
        });

        Ok(state.in_scope(config.scope(), violations))
    }
}

impl Module {
    /// Reads and parses the module at `path`.
    fn read(path: &Path) -> Result<Self, String> {
        let source = fs::read_to_string(path)
            .map_err(|error| format!("could not read {}: {error}", path.display()))?;
        let path = fs::canonicalize(path)
            .map_err(|error| format!("could not resolve {}: {error}", path.display()))?;
        Self::parse(path, &source)
    }

    /// Reads the module name and the tags from `source`, the module at
    /// `path`.
    fn parse(path: PathBuf, source: &str) -> Result<Self, String> {
        let name = MODULE
            .captures(source)
            .map(|captures| captures[1].to_string())
            .ok_or_else(|| {
                format!(
                    "{}: no defmodule found; set paths to the components modules",
                    path.display()
                )
            })?;

        let mut tags: Vec<String> = DEF
            .captures_iter(source)
            .map(|captures| captures[1].to_string())
            .collect();
        tags.sort_unstable();
        tags.dedup();

        if tags.is_empty() {
            return Err(format!(
                "{name} defines no function that could be a tag; set paths to the components modules"
            ));
        }

        Ok(Self { name, path, tags })
    }
}

impl Components {
    /// Puts the modules together. A tag defined in two modules is an error,
    /// since the message could not say which component to use.
    fn new(modules: Vec<Module>) -> Result<Self, String> {
        let mut by_tag: HashMap<String, String> = HashMap::new();
        for module in &modules {
            for tag in &module.tags {
                if let Some(other) = by_tag.insert(tag.clone(), module.name.clone()) {
                    return Err(format!(
                        "{tag}/1 is defined in both {other} and {}; a tag can have one component",
                        module.name
                    ));
                }
            }
        }

        let mut tags: Vec<&str> = by_tag.keys().map(String::as_str).collect();
        tags.sort_unstable();
        let raw_tag = Regex::new(&format!(r"<({})(?:[\s/>]|$)", tags.join("|")))
            .expect("tag names are letters and digits");

        Ok(Self {
            paths: modules.into_iter().map(|module| module.path).collect(),
            modules: by_tag,
            raw_tag,
        })
    }

    /// Whether `file` is one of the components modules. The name is compared
    /// first, so only a file called the same is resolved on disk.
    fn is_module(&self, file: &File) -> bool {
        self.paths
            .iter()
            .any(|path| path.file_name() == file.path.file_name())
            && fs::canonicalize(&file.path).is_ok_and(|path| self.paths.contains(&path))
    }

    /// Every raw tag in `text` as `(byte offset of the <, tag)`.
    fn raw_tags<'a>(&'a self, text: &'a str) -> impl Iterator<Item = (usize, &'a str)> + 'a {
        self.raw_tag.captures_iter(text).map(|captures| {
            let whole = captures.get(0).unwrap();
            (whole.start(), captures.get(1).unwrap().as_str())
        })
    }

    fn message(&self, tag: &str) -> String {
        format!(
            "<{tag}> is a raw tag, use <.{tag}> from {}",
            self.modules[tag]
        )
    }
}

/// The one file called `core_components.ex` under `root`. None or several
/// is an error that says to set the paths.
fn find_module(root: &Path) -> Result<PathBuf, String> {
    let found: Vec<PathBuf> = WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file() && entry.file_name() == DEFAULT_FILE)
        .map(|entry| entry.into_path())
        .collect();

    match found.as_slice() {
        [path] => Ok(path.clone()),
        [] => Err(format!(
            "no {DEFAULT_FILE} under {}; set paths to the components modules",
            root.display()
        )),
        many => Err(format!(
            "{} files called {DEFAULT_FILE} under {}: {}; set paths to the ones to check against",
            many.len(),
            root.display(),
            many.iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// The byte ranges of `file` that are templates: the whole file for `.heex`,
/// otherwise the body of every `~H` sigil. A sigil with no closing delimiter
/// runs to the end of the file, so nothing after it is missed.
fn template_ranges(file: &File) -> Vec<(usize, usize)> {
    let contents = file.contents();
    if file.has_extension(&["heex"]) {
        return vec![(0, contents.len())];
    }

    let mut ranges = Vec::new();
    let mut from = 0;
    while let Some(found) = contents[from..].find("~H") {
        let after = from + found + "~H".len();
        let Some((open, close)) = sigil_delimiters(&contents[after..]) else {
            from = after;
            continue;
        };
        let start = after + open.len();
        match contents[start..].find(close) {
            Some(length) => {
                ranges.push((start, start + length));
                from = start + length + close.len();
            }
            None => {
                ranges.push((start, contents.len()));
                break;
            }
        }
    }
    ranges
}

/// The opening and closing delimiter of the sigil whose body starts `rest`,
/// or `None` when `~H` is not followed by a delimiter. `"""` is tried before
/// `"`.
fn sigil_delimiters(rest: &str) -> Option<(&'static str, &'static str)> {
    const PAIRS: &[(&str, &str)] = &[
        ("\"\"\"", "\"\"\""),
        ("'''", "'''"),
        ("\"", "\""),
        ("'", "'"),
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
        ("<", ">"),
        ("|", "|"),
        ("/", "/"),
    ];
    PAIRS
        .iter()
        .copied()
        .find(|(open, _)| rest.starts_with(open))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::check::testing::{config, run, scoped, state};
    use crate::check::Scope;

    /// A components module with three tags, a private function, and names
    /// that cannot be tags.
    const MODULE_SOURCE: &str = "\
defmodule ExampleWeb.CoreComponents do
  def p(assigns) do
  end

  def h1(assigns) do
  end

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
  end

  def input(assigns) do
  end

  defp error(assigns) do
  end

  def button_link(assigns) do
  end

  def valid?(assigns) do
  end
end
";

    /// A second module with one tag of its own.
    const OTHER_SOURCE: &str = "\
defmodule ExampleWeb.FormComponents do
  def button(assigns) do
  end
end
";

    /// Modules parsed from the given sources without touching the disk.
    fn modules(sources: &[&str]) -> Vec<Module> {
        sources
            .iter()
            .enumerate()
            .map(|(i, source)| Module::parse(PathBuf::from(format!("/{i}.ex")), source).unwrap())
            .collect()
    }

    /// A check prepared from the given sources, so `prepare` has nothing
    /// to read.
    fn check(sources: &[&str]) -> CoreComponentTags {
        let check = CoreComponentTags::new();
        check
            .components
            .set(Components::new(modules(sources)).unwrap())
            .ok()
            .unwrap();
        check
    }

    #[test]
    fn reads_the_module_name_and_the_public_tag_like_functions_once_each() {
        let module = Module::parse(PathBuf::from("/x.ex"), MODULE_SOURCE).unwrap();
        assert_eq!(module.name, "ExampleWeb.CoreComponents");
        assert_eq!(module.tags, vec!["h1", "input", "p"]);

        let components = Components::new(modules(&[MODULE_SOURCE])).unwrap();
        assert_eq!(components.raw_tag.as_str(), r"<(h1|input|p)(?:[\s/>]|$)");
    }

    #[test]
    fn several_modules_pool_their_tags_and_each_tag_names_its_module() {
        let components = Components::new(modules(&[MODULE_SOURCE, OTHER_SOURCE])).unwrap();
        assert_eq!(
            components.raw_tag.as_str(),
            r"<(button|h1|input|p)(?:[\s/>]|$)"
        );
        assert_eq!(
            components.message("button"),
            "<button> is a raw tag, use <.button> from ExampleWeb.FormComponents"
        );
        assert_eq!(
            components.message("p"),
            "<p> is a raw tag, use <.p> from ExampleWeb.CoreComponents"
        );
    }

    #[test]
    fn a_tag_defined_in_two_modules_is_refused() {
        let error = Components::new(modules(&[MODULE_SOURCE, MODULE_SOURCE])).unwrap_err();
        assert!(error.contains("is defined in both ExampleWeb.CoreComponents and"));
    }

    #[test]
    fn a_file_without_a_module_or_without_tags_is_refused() {
        let error = Module::parse(PathBuf::from("/x.ex"), "def p(assigns)").unwrap_err();
        assert!(error.contains("no defmodule found"));

        let error = Module::parse(PathBuf::from("/x.ex"), "defmodule A do\nend\n").unwrap_err();
        assert!(error.contains("A defines no function that could be a tag"));
    }

    #[test]
    fn a_template_file_is_all_template() {
        let check = check(&[MODULE_SOURCE]);
        let state = state()
            .file(
                "a.heex",
                "<p class=\"x\">hi</p>\n<h1>\n<.p>\n</p>\n<pre>\n<path d=\"\" />\n<input\n  type=\"text\"\n/>\n<p>",
            )
            .build();
        assert_eq!(
            run(&check, &state, &config(&check, &[])),
            vec![
                "a.heex:1: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
                "a.heex:2: <h1> is a raw tag, use <.h1> from ExampleWeb.CoreComponents",
                "a.heex:7: <input> is a raw tag, use <.input> from ExampleWeb.CoreComponents",
                "a.heex:10: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
            ]
        );
    }

    #[test]
    fn an_elixir_file_only_counts_inside_sigils() {
        let check = check(&[MODULE_SOURCE]);
        let state = state()
            .file(
                "a.ex",
                "@doc \"\"\"\n  <h1>Content</h1>\n\"\"\"\ndef app(assigns) do\n  ~H\"\"\"\n  <header>\n  <p>\n  \"\"\"\nend\n# <p>\n~H\"<input />\"\n",
            )
            .build();
        assert_eq!(
            run(&check, &state, &config(&check, &[])),
            vec![
                "a.ex:7: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
                "a.ex:11: <input> is a raw tag, use <.input> from ExampleWeb.CoreComponents",
            ]
        );
    }

    #[test]
    fn only_elixir_and_template_files_are_read() {
        let check = check(&[MODULE_SOURCE]);
        let state = state()
            .file("notes.md", "<p>")
            .file("a.exs", "~H\"<p>\"")
            .file("b.heex", "<p>")
            .build();
        assert_eq!(
            run(&check, &state, &config(&check, &[])),
            vec!["b.heex:1: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents"]
        );
    }

    #[test]
    fn tags_from_every_module_are_reported() {
        let check = check(&[MODULE_SOURCE, OTHER_SOURCE]);
        let state = state().file("a.heex", "<h1>\n<button>\n<div>\n").build();
        assert_eq!(
            run(&check, &state, &config(&check, &[])),
            vec![
                "a.heex:1: <h1> is a raw tag, use <.h1> from ExampleWeb.CoreComponents",
                "a.heex:2: <button> is a raw tag, use <.button> from ExampleWeb.FormComponents",
            ]
        );
    }

    #[test]
    fn the_changed_scope_reports_changed_lines_in_changed_files_only() {
        let check = check(&[MODULE_SOURCE]);
        let state = state()
            .file("old.heex", "<p>\n")
            .changed("edited.heex", "<p>\n<p>\n<p>\n", &[2])
            .added("new.heex", "<p>\n")
            .build();
        assert_eq!(
            run(&check, &state, &scoped(&check, Scope::Changed, &[])),
            vec![
                "edited.heex:2: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
                "new.heex:1: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
            ]
        );
    }

    #[test]
    fn an_unclosed_sigil_runs_to_the_end_of_the_file() {
        let file = File::with_contents("a.ex", "~H\"\"\"\n<p>\n<p>\n");
        assert_eq!(template_ranges(&file), vec![(5, 14)]);
    }

    #[test]
    fn sigils_with_other_delimiters_and_text_that_is_not_a_sigil() {
        let file = File::with_contents("a.ex", "~H[<p>] ~Hx ~H(<p>) ~H|<p>|");
        assert_eq!(
            template_ranges(&file),
            vec![(3, 6), (15, 18), (23, 26)]
        );
        assert_eq!(
            template_ranges(&File::with_contents("a.heex", "<p>")),
            vec![(0, 3)]
        );
    }

    #[test]
    fn prepare_reads_every_given_path_and_skips_those_files() {
        let dir = std::env::temp_dir().join(format!("component-tags-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let core = dir.join("core_components.ex");
        let form = dir.join("form_components.ex");
        std::fs::write(&core, MODULE_SOURCE).unwrap();
        std::fs::write(&form, OTHER_SOURCE).unwrap();

        let check = CoreComponentTags::new();
        let config = config(
            &check,
            &[
                ("paths", core.to_str().unwrap()),
                ("paths", form.to_str().unwrap()),
            ],
        );
        let state = state()
            .file(core.to_str().unwrap(), "~H\"<p><button>\"")
            .file(form.to_str().unwrap(), "~H\"<p><button>\"")
            .file("other.heex", "<p>\n<button>")
            .build();
        assert_eq!(
            run(&check, &state, &config),
            vec![
                "other.heex:1: <p> is a raw tag, use <.p> from ExampleWeb.CoreComponents",
                "other.heex:2: <button> is a raw tag, use <.button> from ExampleWeb.FormComponents",
            ]
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prepare_refuses_a_missing_path_and_a_missing_default() {
        let check = CoreComponentTags::new();
        let error = check
            .prepare(&config(&check, &[("paths", "/no/such/file.ex")]))
            .unwrap_err();
        assert!(error.starts_with("could not read /no/such/file.ex"));

        // cargo runs tests from priv/checks, which has no lib directory.
        let error = check.prepare(&config(&check, &[])).unwrap_err();
        assert_eq!(
            error,
            "no core_components.ex under lib; set paths to the components modules"
        );
    }

    #[test]
    fn find_module_wants_exactly_one_file() {
        let dir = std::env::temp_dir().join(format!("component-tags-two-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("a")).unwrap();
        std::fs::create_dir_all(dir.join("b")).unwrap();
        std::fs::write(dir.join("a").join(DEFAULT_FILE), "").unwrap();

        assert_eq!(
            find_module(&dir).unwrap(),
            dir.join("a").join(DEFAULT_FILE)
        );

        std::fs::write(dir.join("b").join(DEFAULT_FILE), "").unwrap();
        let error = find_module(&dir).unwrap_err();
        assert!(error.starts_with("2 files called core_components.ex under"));
        assert!(error.ends_with("set paths to the ones to check against"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
