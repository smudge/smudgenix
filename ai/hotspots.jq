# smx ai's deterministic review hotspots: what in a change deserves a closer
# look, found mechanically (an agent's own concerns come separately). Not a
# judgment of correctness; a way to point your attention.
#
# In: {"files": [{status, path, added, removed}…],
#      "lines": [{path, hunk, text}…]}     (the change's added lines)
# where status is git's (A, M, D, R…) and hunk its "@@ … @@" header.
# Out: [{kind, path, hunk, why}…], hunk null for a whole file, at most one
# per kind, path and hunk. Kinds: dependencies, tests, migration, ci,
# security, size.
#
#   jq -f hotspots.jq < change.json

def name: split("/") | last;

def dependency_file:
  name | test("^(flake\\.lock|Cargo\\.(toml|lock)|package(-lock)?\\.json|pnpm-lock\\.yaml|yarn\\.lock|go\\.(mod|sum)|Gemfile(\\.lock)?|.*\\.gemspec|requirements.*\\.txt|pyproject\\.toml|poetry\\.lock|uv\\.lock|composer\\.(json|lock)|mix\\.(exs|lock))$");

def test_file:
  test("(^|/)(tests?|spec|__tests__)/|(_test|_spec|\\.test|\\.spec)\\.[a-z]+$|(^|/)test_[^/]*\\.py$");

def migration_file: test("(^|/)(db/)?migrat(e|ions?)/|migration"; "i");

def ci_file: test("^\\.github/workflows/|^\\.gitlab-ci|^\\.circleci/|(^|/)Jenkinsfile$|^\\.buildkite/");

def security_file: test("sandbox|permission|polic(y|ies)|auth|secret|credential|security|sudoers|\\.ssh/"; "i");

# Added lines that skip a test, or look like they weaken security.
def skips_test: test("\\.skip\\(|\\bx(it|describe)\\(|@(pytest\\.mark\\.)?skip|#\\[ignore\\]|\\bt\\.Skip\\(|pending\\(|\\.only\\(");
def risky_line:
  test("chmod\\s+(-R\\s+)?(777|a\\+w)|curl[^|]*\\|\\s*(ba)?sh|--no-verify|disable.?(ssl|tls|verification)|verify\\s*=\\s*false|NOPASSWD|eval\\("; "i");

[
  (.files[] |
    if (.path | dependency_file) then
      {kind: "dependencies", path, hunk: null, why: "Dependencies change here"}
    else empty end,
    if (.path | test_file) and .status == "D" then
      {kind: "tests", path, hunk: null, why: "A test file is deleted"}
    elif (.path | test_file) and .removed > 10 and .removed > 2 * .added then
      {kind: "tests", path, hunk: null, why: "Tests shrink: \(.removed) lines out, \(.added) in"}
    else empty end,
    if (.path | migration_file) then
      {kind: "migration", path, hunk: null, why: "A migration: it changes stored data"}
    else empty end,
    if (.path | ci_file) then
      {kind: "ci", path, hunk: null, why: "CI changes: what checks the work"}
    else empty end,
    if (.path | security_file) then
      {kind: "security", path, hunk: null, why: "Security-sensitive by name: sandboxing, permissions, auth or secrets"}
    else empty end,
    if (.added + .removed) > 300 then
      {kind: "size", path, hunk: null, why: "A large change: \(.added) lines in, \(.removed) out"}
    else empty end),
  (.lines[] |
    if (.text | skips_test) then
      {kind: "tests", path, hunk, why: "A test is skipped or narrowed"}
    elif (.text | risky_line) then
      {kind: "security", path, hunk, why: "This line may weaken security"}
    else empty end)
]
| unique_by([.kind, .path, .hunk])
