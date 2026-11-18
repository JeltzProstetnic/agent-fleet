#!/usr/bin/env bash
# Tests for persona system — validates machine file format and persona parsing
source "$(dirname "$0")/test-helpers.sh"

suite_header "Persona System"

# ── Machine file template has persona section ────────────────────────────────

test_template_has_persona() {
    local template="$REPO_ROOT/global/machines/_template.md"
    assert_file_exists "$template"
    assert_file_contains "$template" "## Persona"
    assert_file_contains "$template" "Activates"
    assert_file_contains "$template" "Traits"
    assert_file_contains "$template" "Style"
}
run_test "machine template includes persona section with all fields" test_template_has_persona

# ── Global personas file has default personas ────────────────────────────────

test_global_personas() {
    local personas="$REPO_ROOT/global/foundation/personas.md"
    assert_file_exists "$personas"
    assert_file_contains "$personas" "## Persona"
    assert_file_contains "$personas" "### Assistant"
    assert_file_contains "$personas" "### Supporter"
}
run_test "global personas file has default personas" test_global_personas

# ── Persona fields are parseable ─────────────────────────────────────────────

test_persona_fields_parseable() {
    local personas="$REPO_ROOT/global/foundation/personas.md"

    # Extract Assistant's activation rule
    local assistant_section
    assistant_section=$(sed -n '/^### Assistant$/,/^### /{/^### Assistant$/d;/^### /d;p}' "$personas")
    assert_contains "$assistant_section" "default"
    assert_contains "$assistant_section" "Activates"

    # Extract Supporter's activation rule
    local supporter_section
    supporter_section=$(sed -n '/^### Supporter$/,/^## [^P]/{/^### Supporter$/d;/^## /d;p}' "$personas")
    assert_contains "$supporter_section" "frustrated"
    assert_contains "$supporter_section" "Activates"
}
run_test "persona activation rules are parseable from global file" test_persona_fields_parseable

# ── Multiple personas can be defined ─────────────────────────────────────────

test_multiple_personas() {
    # Create a test machine file with 3 personas
    cat > "$TEST_TMPDIR/test-machine.md" <<'EOF'
# Machine: Test

## Identity
- **Short name**: Test

## Persona

### Alpha
- **Name**: Alpha
- **Traits**: efficient, direct
- **Activates**: default
- **Color**: cyan
- **Style**: All business.

### Beta
- **Name**: Beta
- **Traits**: creative, playful
- **Activates**: when brainstorming or discussing ideas
- **Color**: green
- **Style**: Exploratory and fun.

### Gamma
- **Name**: Gamma
- **Traits**: empathetic, warm
- **Activates**: when user is frustrated or tired
- **Color**: magenta
- **Style**: Understanding and supportive.

## Known Issues
- None
EOF

    # Count persona subsections under ## Persona
    local persona_count
    persona_count=$(awk '/^## Persona/,/^## [^P]/ { if (/^### /) count++ } END { print count+0 }' "$TEST_TMPDIR/test-machine.md")
    assert_eq "3" "$persona_count" "should detect 3 personas"
}
run_test "supports arbitrary number of personas per machine" test_multiple_personas

# ── Global CLAUDE.md has persona rendering rules ─────────────────────────────

test_global_rules() {
    local global="$REPO_ROOT/global/CLAUDE.md"
    assert_file_contains "$global" "## Persona System"
    assert_file_contains "$global" "personas.md"
    assert_file_contains "$global" "persona-rules.md"
    assert_file_contains "$global" ".active-persona"
}
run_test "global CLAUDE.md contains persona rendering rules" test_global_rules

# ── Onboarding mentions persona ──────────────────────────────────────────────

test_onboarding_persona() {
    local onboard="$REPO_ROOT/global/foundation/first-run-refinement.md"
    assert_file_contains "$onboard" "Configure Agent Personas"
    assert_file_contains "$onboard" "persona patterns"
}
run_test "first-run onboarding includes persona configuration step" test_onboarding_persona

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
