//! Human review: a changed path that matches one of the patterns needs an
//! engineer to review the pull request, not only an automated reviewer.
//!
//! This is for feature work: contexts, schemas, LiveView modules,
//! migrations, tests. Paths that match nothing, such as templates and
//! docs, can go through an automated review alone. The config lists the
//! patterns under `paths`. A pattern matches the whole path from the
//! project root. `*` does not cross a `/`, `**` does.
//!
//! The check is about the branch, so it reads what the branch changed
//! whatever its scope is. Every violation is about a file. The usual level
//! is `warning`, so the run prints which files need an engineer without
//! failing. Pair it with a CODEOWNERS file that requires the approval.

use crate::check::{glob_set, Check, Config, State, Violation};

pub struct HumanReview;

/// The check this file contributes. Every file in `src/checks/` exports one.
pub const CHECK: &dyn Check = &HumanReview;

impl Check for HumanReview {
    fn name(&self) -> &'static str {
        "human_review"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["paths"]
    }

    fn prepare(&self, config: &Config) -> Result<(), String> {
        glob_set("paths", &config.many("paths")).map(|_| ())
    }

    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
        let paths = glob_set("paths", &config.many("paths"))?;
        Ok(state
            .changed()
            .iter()
            .filter(|file| paths.is_match(&file.path))
            .map(|file| Violation::file(&file.path, "ask an engineer to review this change"))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::check::testing::{config, error, run, state};

    const PATHS: &[(&str, &str)] = &[
        ("paths", "lib/example/**"),
        ("paths", "lib/example_web/**/*.ex"),
        ("paths", "test/**"),
    ];

    #[test]
    fn reports_each_changed_path_that_matches() {
        let state = state()
            .changed("lib/example/orders.ex", "", &[1])
            .added("lib/example_web/live/home_live.ex", "")
            .added("lib/example_web/live/home_live.html.heex", "")
            .changed("docs/readme.md", "", &[1])
            .file("test/example/orders_test.exs", "")
            .build();
        assert_eq!(
            run(&HumanReview, &state, &config(&HumanReview, PATHS)),
            vec![
                "lib/example/orders.ex: ask an engineer to review this change",
                "lib/example_web/live/home_live.ex: ask an engineer to review this change",
            ]
        );
    }

    #[test]
    fn no_paths_is_an_error() {
        assert_eq!(
            error(&HumanReview, &state().build(), &config(&HumanReview, &[])),
            "set paths to at least one path pattern"
        );
    }
}
