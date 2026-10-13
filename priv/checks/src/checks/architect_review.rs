//! Architect review: a changed path that matches one of the patterns needs
//! an architect to review the pull request.
//!
//! This is for shared code, configuration and dependencies: the router,
//! the components, `config/`, `mix.exs`, the CI workflows. The config
//! lists the patterns under `paths`. A pattern matches the whole path from
//! the project root. `*` does not cross a `/`, `**` does.
//!
//! The check is about the branch, so it reads what the branch changed
//! whatever its scope is. Every violation is about a file. The usual level
//! is `warning`, so the run prints which files need an architect without
//! failing. Pair it with a CODEOWNERS file that requires the approval.

use crate::check::{glob_set, Check, Config, State, Violation};

pub struct ArchitectReview;

/// The check this file contributes. Every file in `src/checks/` exports one.
pub const CHECK: &dyn Check = &ArchitectReview;

impl Check for ArchitectReview {
    fn name(&self) -> &'static str {
        "architect_review"
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
            .map(|file| Violation::file(&file.path, "ask an architect to review this change"))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::check::testing::{config, error, run, state};

    const PATHS: &[(&str, &str)] = &[
        ("paths", "config/**"),
        ("paths", "mix.exs"),
        ("paths", "lib/example_web/router.ex"),
    ];

    #[test]
    fn reports_each_changed_path_that_matches() {
        let state = state()
            .changed("config/dev.exs", "", &[1])
            .changed("configs/dev.exs", "", &[1])
            .deleted("mix.exs")
            .added("lib/example_web/live/home_live.ex", "")
            .file("lib/example_web/router.ex", "")
            .build();
        assert_eq!(
            run(&ArchitectReview, &state, &config(&ArchitectReview, PATHS)),
            vec![
                "config/dev.exs: ask an architect to review this change",
                "mix.exs: ask an architect to review this change",
            ]
        );
    }

    #[test]
    fn no_paths_or_a_bad_pattern_is_an_error() {
        let state = state().build();
        assert_eq!(
            error(&ArchitectReview, &state, &config(&ArchitectReview, &[])),
            "set paths to at least one path pattern"
        );
        let error = error(
            &ArchitectReview,
            &state,
            &config(&ArchitectReview, &[("paths", "[")]),
        );
        assert!(error.starts_with("paths: [ is not a valid pattern"));
    }
}
