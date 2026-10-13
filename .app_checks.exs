# Configuration for `mix app_checks` run inside this library. priv/checks is
# the crate itself here, not a directory of the project's own checks, there
# is no components module under lib, and the review checks have nothing to
# say about a library.
%{
  custom_checks: "test/fixtures/custom_checks",
  configs: [
    %{
      name: "default",
      base_ref: "main",
      checks: [
        enabled: [
          {:core_component_tags, config: [paths: ["test/fixtures/core_components.ex"]]}
        ],
        disabled: [:separate_pr, :architect_review, :human_review]
      ]
    }
  ]
}
