#!/usr/bin/env bash
# sync-lib/check.sh — Check and validation commands for sync.sh
#
# Provides: cmd_check, cmd_check_template, check_personal_data_leaks, check_template_drift
#
# Expects these from the caller (sync.sh):
#   SCRIPT_DIR, GLOBAL_DIR, CLAUDE_HOME
#   log_info, log_warn, log_error (functions)
#   find_project_path, _extract_manifest_section (from common.sh)
#   PERSONAL_DATA_PATTERNS (optional, from sync.local.sh)

# ---- Personal data leak check on template ----
check_personal_data_leaks() {
    local template_dir="$HOME/agent-fleet"
    [ -d "$template_dir" ] || return 0

    local check_pattern="${PERSONAL_DATA_PATTERNS:-}"
    if [[ -z "$check_pattern" ]]; then
        return 0
    fi

    # Check for personal machine files (anything in machines/ that isn't _template.md or INDEX.md)
    local personal_machines=()
    if [ -d "$template_dir/global/machines" ]; then
        while IFS= read -r mfile; do
            local bname
            bname="$(basename "$mfile")"
            [[ "$bname" == "_template.md" || "$bname" == "INDEX.md" ]] && continue
            personal_machines+=("$mfile")
        done < <(find "$template_dir/global/machines" -name "*.md" -type f 2>/dev/null)
    fi

    if [ ${#personal_machines[@]} -gt 0 ]; then
        log_warn "Personal machine files in template (should only have _template.md + INDEX.md):"
        for mf in "${personal_machines[@]}"; do
            log_warn "  $(basename "$mf")"
        done
    fi

    # Check for personal content in volatile files
    local vpath
    # inbox.md: personal tasks show up as "- [ ] **project**:" entries
    vpath="$template_dir/cross-project/inbox.md"
    if [ -f "$vpath" ]; then
        local task_lines
        task_lines=$(grep -c '^\- \[.\] \*\*' "$vpath" 2>/dev/null) || task_lines=0
        if [ "$task_lines" -gt 0 ]; then
            log_warn "Volatile file has personal tasks: cross-project/inbox.md ($task_lines task entries)"
        fi
    fi
    # session-log.md: personal sessions show up as "### YYYY-MM-DD" entries
    vpath="$template_dir/docs/session-log.md"
    if [ -f "$vpath" ]; then
        local session_lines
        session_lines=$(grep -c '^### [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "$vpath" 2>/dev/null) || session_lines=0
        if [ "$session_lines" -gt 0 ]; then
            log_warn "Volatile file has personal sessions: docs/session-log.md ($session_lines session entries)"
        fi
    fi
    # dashboard-cache.md: personal data shows up as non-header table rows
    vpath="$template_dir/cross-project/dashboard-cache.md"
    if [ -f "$vpath" ]; then
        local data_rows
        data_rows=$(grep -c '^|[^-]' "$vpath" 2>/dev/null) || data_rows=0
        if [ "$data_rows" -gt 1 ]; then
            log_warn "Volatile file has personal data: cross-project/dashboard-cache.md ($((data_rows - 1)) data rows)"
        fi
    fi
    # session-context.md / session-history.md: should not exist in template
    for vf in session-context.md session-history.md; do
        vpath="$template_dir/$vf"
        if [ -f "$vpath" ] && [ -s "$vpath" ]; then
            log_warn "Volatile file should not exist in template: $vf"
        fi
    done

    local leak_count=0
    local hits
    hits=$(grep -rn --include='*.md' --include='*.sh' --include='*.json' --include='*.yml' --include='*.yaml' \
        -E "$check_pattern" \
        "$template_dir" 2>/dev/null \
        | grep -v '\.git/' \
        | grep -v "PERSONAL_DATA_PATTERNS" \
        | grep -v 'setup/tests/.*\.sh:.*echo.*Contact' \
        | grep -v 'github\.com/.*/agent-fleet\.git' \
        || true)

    if [ -n "$hits" ]; then
        leak_count=$(echo "$hits" | wc -l)
        log_warn "Personal data patterns found in template ($leak_count occurrence(s)):"
        echo "$hits" | head -10 | while IFS= read -r line; do
            log_warn "  $line"
        done
        if [ "$leak_count" -gt 10 ]; then
            log_warn "  ... and $((leak_count - 10)) more"
        fi
        log_warn "Review these before pushing the template to a public repo."
    fi
}

# ---- Template drift check (hash-based) ----
check_template_drift() {
    local template_dir="$HOME/agent-fleet"
    [ -d "$template_dir" ] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not found — skipping template drift check"
        return 0
    fi

    local manifest="$SCRIPT_DIR/template-sync-manifest.md"
    [ -f "$manifest" ] || { log_warn "template-sync-manifest.md missing — cannot check template drift"; return 0; }

    local drift_count=0
    local tracked_files
    tracked_files=$(grep -oP '^\| `[^`]+` \| `[0-9a-f]{8}`' "$manifest" | sed 's/^| `//;s/` | `/|/;s/`$//' || true)

    local line file_path hash
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        file_path="${line%%|*}"
        hash="${line##*|}"
        [ -n "$file_path" ] && [ -n "$hash" ] || continue

        local full_path="$SCRIPT_DIR/$file_path"
        [ -f "$full_path" ] || continue

        local current_hash
        current_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$full_path")

        if [ "$current_hash" != "$hash" ]; then
            log_warn "$file_path: hash stale ($hash → $current_hash). Propagate structural changes, then run 'sync.sh stamp'"
            drift_count=$((drift_count + 1))
        fi
    done <<< "$tracked_files"

    if [ "$drift_count" -gt 0 ]; then
        log_warn "$drift_count file(s) drifted. Review and propagate to template."
    fi
}

# ---- CHECK: Aggregated drift/staleness check ----
# Usage: bash sync.sh check [--repo-root PATH] [--template-dir PATH]
cmd_check() {
    local check_repo_root="$SCRIPT_DIR"
    local check_template_dir="$HOME/agent-fleet"
    local check_mobile_dir="$HOME/agent-fleet-mobile"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-root)     check_repo_root="$2"; shift 2 ;;
            --template-dir)  check_template_dir="$2"; shift 2 ;;
            --mobile-dir)    check_mobile_dir="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local total_issues=0

    # ── 1. Template drift (smart: byte-diff for identical, hash for intentional) ──
    log_info "Checking template drift..."
    local manifest="$check_repo_root/template-sync-manifest.md"
    if [ ! -f "$manifest" ]; then
        log_warn "template-sync-manifest.md missing — cannot check template drift"
        total_issues=$((total_issues + 1))
    elif ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not found — skipping template drift check"
    else
        local drift_count=0

        local identical_files intentional_files
        identical_files=$(_extract_manifest_section "Must Be Identical" "$manifest")
        intentional_files=$(_extract_manifest_section "Intentional Diffs" "$manifest")

        # ── 1a. "Must Be Identical" files ──
        local line file_path hash
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            file_path="${line%%|*}"
            hash="${line##*|}"
            [ -n "$file_path" ] && [ -n "$hash" ] || continue

            local personal_file="$check_repo_root/$file_path"
            [ -f "$personal_file" ] || continue

            if [ -d "$check_template_dir" ]; then
                local template_file="$check_template_dir/$file_path"
                if [ -f "$template_file" ]; then
                    if ! diff -q "$personal_file" "$template_file" >/dev/null 2>&1; then
                        log_warn "$file_path differs from template — propagate update"
                        drift_count=$((drift_count + 1))
                    fi
                else
                    local current_hash
                    current_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$personal_file")
                    if [ "$current_hash" != "$hash" ]; then
                        log_warn "$file_path drifted (was: $hash, now: $current_hash) — template file missing"
                        drift_count=$((drift_count + 1))
                    fi
                fi
            else
                local current_hash
                current_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$personal_file")
                if [ "$current_hash" != "$hash" ]; then
                    log_warn "$file_path drifted (was: $hash, now: $current_hash)"
                    drift_count=$((drift_count + 1))
                fi
            fi
        done <<< "$identical_files"

        # ── 1b. "Intentional Diffs" files ──
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            file_path="${line%%|*}"
            hash="${line##*|}"
            [ -n "$file_path" ] && [ -n "$hash" ] || continue

            local personal_file="$check_repo_root/$file_path"
            [ -f "$personal_file" ] || continue

            local current_hash
            current_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$personal_file")

            if [ "$current_hash" != "$hash" ]; then
                log_warn "$file_path: hash stale ($hash → $current_hash). Propagate structural changes, then run 'sync.sh stamp'"
                drift_count=$((drift_count + 1))
            fi
        done <<< "$intentional_files"

        if [ "$drift_count" -gt 0 ]; then
            log_warn "Template: $drift_count file(s) drifted"
            total_issues=$((total_issues + drift_count))
        else
            log_info "Template: clean"
        fi
    fi

    # ── 2. Personal data leak check ──
    local check_pattern="${PERSONAL_DATA_PATTERNS:-}"
    if [ -d "$check_template_dir" ] && [ -n "$check_pattern" ]; then
        log_info "Checking template for sensitive patterns..."
        local hits
        hits=$(grep -rn --include='*.md' --include='*.sh' --include='*.json' --include='*.yml' --include='*.yaml' \
            -E "$check_pattern" \
            "$check_template_dir" 2>/dev/null \
            | grep -v '\.git/' \
            | grep -v "PERSONAL_DATA_PATTERNS" \
            | grep -v 'setup/tests/.*\.sh:.*echo.*Contact' \
            | grep -v 'github\.com/.*/agent-fleet\.git' \
            || true)

        if [ -n "$hits" ]; then
            local leak_count
            leak_count=$(echo "$hits" | wc -l)
            log_warn "personal data patterns found in template ($leak_count occurrence(s)):"
            echo "$hits" | head -5 | while IFS= read -r line; do
                log_warn "  $line"
            done
            total_issues=$((total_issues + leak_count))
        else
            log_info "Template: clean (no sensitive patterns found)"
        fi
    fi

    # ── 3. Mobile staleness ──
    if [ -d "$check_mobile_dir" ]; then
        log_info "Checking mobile repo staleness..."
        local mobile_script="$check_repo_root/setup/scripts/mobile-deploy.sh"
        if [ -f "$mobile_script" ]; then
            local mobile_out
            mobile_out=$(bash "$mobile_script" --check-staleness --config-repo "$check_repo_root" --target "$check_mobile_dir" 2>&1)
            echo "$mobile_out" | grep -v '^\[' || true
            if echo "$mobile_out" | grep -q "is stale"; then
                total_issues=$((total_issues + 1))
            else
                log_info "Mobile: up to date"
            fi
        fi
    else
        log_info "Mobile repo not present — skipping"
    fi

    # ── 4. Hook drift (repo vs deployed) ──
    log_info "Checking hook drift..."
    local hook_drift=0
    if [ -d "$check_repo_root/global/hooks" ] && [ -d "$CLAUDE_HOME/hooks" ]; then
        for hook in "$check_repo_root/global/hooks/"*.sh; do
            [ -f "$hook" ] || continue
            local base
            base=$(basename "$hook")
            local deployed="$CLAUDE_HOME/hooks/$base"
            if [ ! -f "$deployed" ]; then
                log_warn "Hook $base: not deployed"
                hook_drift=$((hook_drift + 1))
            elif ! diff -q "$hook" "$deployed" >/dev/null 2>&1; then
                log_warn "Hook $base: drifted (repo ≠ deployed)"
                hook_drift=$((hook_drift + 1))
            fi
        done
    fi
    if [ "$hook_drift" -eq 0 ]; then
        log_info "Hooks: clean"
    else
        total_issues=$((total_issues + hook_drift))
    fi

    # ── 5. Project rule drift (repo vs deployed) ──
    log_info "Checking project rule drift..."
    local rule_drift=0
    if [ -d "$check_repo_root/setup/projects" ]; then
        for project_dir in "$check_repo_root/setup/projects"/*/; do
            [ -d "$project_dir" ] || continue
            local project_name
            project_name=$(basename "$project_dir")
            local project_path
            project_path=$(find_project_path "$project_name")
            [ -n "$project_path" ] && [ -d "$project_path" ] || continue

            for rule in "$project_dir/rules/"*.md; do
                [ -f "$rule" ] || continue
                local base
                base=$(basename "$rule")
                local target="$project_path/.claude/$base"
                if [ ! -f "$target" ]; then
                    log_warn "Rule $project_name/$base: not deployed"
                    rule_drift=$((rule_drift + 1))
                elif ! diff -q "$rule" "$target" >/dev/null 2>&1; then
                    log_warn "Rule $project_name/$base: drifted (repo ≠ deployed)"
                    rule_drift=$((rule_drift + 1))
                fi
            done
        done
    fi
    if [ "$rule_drift" -eq 0 ]; then
        log_info "Project rules: clean"
    else
        total_issues=$((total_issues + rule_drift))
    fi

    # ── Summary ──
    echo ""
    if [ "$total_issues" -eq 0 ]; then
        log_info "All propagation chains clean ✓"
    else
        log_warn "$total_issues issue(s) found across propagation chains"
    fi
}

# ---- CHECK-TEMPLATE: Pre-publish template check ----
cmd_check_template() {
    local repo_root="$SCRIPT_DIR"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-root) repo_root="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local total_issues=0

    # ── 1. Verify .push-filter.conf exists ──
    local config="$repo_root/.push-filter.conf"
    if [[ ! -f "$config" ]]; then
        log_error ".push-filter.conf not found in $repo_root"
        log_error "Create one before publishing. See setup/scripts/filtered-push.sh for format."
        return 1
    fi
    log_info ".push-filter.conf found"

    # ── 2. Parse config and validate required fields ──
    local private_remote="" public_remote="" branch=""
    local -a exclude_paths=() exclude_globs=()

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"
        case "$key" in
            private_remote) private_remote="$value" ;;
            public_remote)  public_remote="$value" ;;
            branch)         branch="$value" ;;
            exclude)        exclude_paths+=("$value") ;;
            exclude_glob)   exclude_globs+=("$value") ;;
        esac
    done < "$config"

    if [[ -z "$private_remote" ]]; then
        log_error "private_remote not set in .push-filter.conf"
        total_issues=$((total_issues + 1))
    fi
    if [[ -z "$public_remote" ]]; then
        log_error "public_remote not set in .push-filter.conf"
        total_issues=$((total_issues + 1))
    fi

    if [[ $total_issues -gt 0 ]]; then
        return 1
    fi

    # ── 3. Check required exclusions are present ──
    local -a required_excludes=(
        "session-context.md"
        "session-history.md"
        "next-session-task.md"
        "cross-project/inbox.md"
        "cross-project/dashboard-cache.md"
        "docs/session-log.md"
        "registry.md"
    )
    local -a required_globs=(
        "global/machines/*.md"
        "docs/pending-*.md"
    )

    local missing=0
    for req in "${required_excludes[@]}"; do
        local found=false
        for exc in "${exclude_paths[@]}"; do
            [[ "$exc" == "$req" ]] && { found=true; break; }
        done
        if ! $found; then
            log_warn "Missing required exclusion: $req"
            missing=$((missing + 1))
        fi
    done
    for req in "${required_globs[@]}"; do
        local found=false
        for exc in "${exclude_globs[@]}"; do
            [[ "$exc" == "$req" ]] && { found=true; break; }
        done
        if ! $found; then
            log_warn "Missing required exclusion (glob): $req"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_error "Missing required exclusion(s): $missing. Fix .push-filter.conf before publishing."
        total_issues=$((total_issues + missing))
    else
        log_info "All required exclusions present"
    fi

    # ── 4. Scan non-excluded files for personal data patterns ──
    local pattern="${PERSONAL_DATA_PATTERNS:-}"
    if [[ -n "$pattern" ]]; then
        local -a find_excludes=()
        for exc in "${exclude_paths[@]}"; do
            find_excludes+=(-path "$repo_root/$exc" -prune -o)
        done
        for exc in "${exclude_globs[@]}"; do
            find_excludes+=(-path "$repo_root/$exc" -prune -o)
        done

        local hits=""
        hits=$(find "$repo_root" \
            -path "$repo_root/.git" -prune -o \
            "${find_excludes[@]}" \
            \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \) \
            -print0 2>/dev/null \
            | xargs -0 grep -lE "$pattern" 2>/dev/null \
            | grep -v "PERSONAL_DATA_PATTERNS" \
            | grep -v 'setup/tests/' \
            || true)

        if [[ -n "$hits" ]]; then
            local leak_count
            leak_count=$(echo "$hits" | wc -l)
            log_error "Found personal data in $leak_count publishable file(s):"
            echo "$hits" | while IFS= read -r f; do
                log_warn "  ${f#$repo_root/}"
            done
            total_issues=$((total_issues + leak_count))
        else
            log_info "No personal data in publishable files"
        fi
    fi

    # ── Summary ──
    echo ""
    if [[ $total_issues -eq 0 ]]; then
        log_info "Template pre-publish check: clean"
        return 0
    else
        log_error "Template pre-publish check: $total_issues issue(s) found"
        return 1
    fi
}
