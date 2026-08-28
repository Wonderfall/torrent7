function string_field(line, key, value) {
    value = line
    sub(".*\\\"" key "\\\":\\\"", "", value)
    sub("\\\".*", "", value)
    return value
}

function number_field(line, key, value) {
    value = line
    sub(".*\\\"" key "\\\":", "", value)
    sub("[,}].*", "", value)
    return value + 0
}

FILENAME == ARGV[1] {
    if ($0 == "" || $0 ~ /^#/) next
    if (NF != 2 || $2 !~ /^[0-9]+$/ || $2 <= 0) {
        print "invalid parser p99 budget: " $0 > "/dev/stderr"
        invalid = 1
        next
    }
    if ($1 in budgets) {
        print "duplicate parser p99 budget: " $1 > "/dev/stderr"
        invalid = 1
        next
    }
    budgets[$1] = $2 + 0
    budget_count += 1
    next
}

{
    runtime = string_field($0, "runtime")
    name = string_field($0, "name")
    p99 = number_field($0, "p99_ns")
    key = FILENAME SUBSEP name

    if (runtime != "swift") {
        print "p99 budget input is not a Swift result: " FILENAME > "/dev/stderr"
        invalid = 1
    }
    if (index($0, "\"p99_ns\":") == 0 || p99 <= 0) {
        print "invalid or missing parser p99 result: " FILENAME > "/dev/stderr"
        invalid = 1
    }
    if (!(name in budgets)) {
        print "missing parser p99 budget for workload: " name > "/dev/stderr"
        invalid = 1
    } else if (key in seen) {
        print "duplicate parser result for workload: " name " in " FILENAME > "/dev/stderr"
        invalid = 1
    } else {
        seen[key] = 1
        observed[name] += 1
        if (p99 > budgets[name]) {
            printf "parser p99 budget exceeded: %s %.2f ns > %d ns (%s)\n", \
                name, p99, budgets[name], FILENAME > "/dev/stderr"
            invalid = 1
        }
    }
}

END {
    result_file_count = ARGC - 2
    if (budget_count == 0 || result_file_count < 1) {
        print "parser p99 budget verification received no data" > "/dev/stderr"
        invalid = 1
    }
    for (name in budgets) {
        if (observed[name] != result_file_count) {
            printf "expected %d results for budgeted workload %s, found %d\n", \
                result_file_count, name, observed[name] + 0 > "/dev/stderr"
            invalid = 1
        }
    }
    if (invalid) exit 2
    printf "Parser p99 budgets passed for %d workloads across %d passes.\n", \
        budget_count, result_file_count
}
