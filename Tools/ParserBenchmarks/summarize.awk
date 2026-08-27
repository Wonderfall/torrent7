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

{
    runtime = string_field($0, "runtime")
    name = string_field($0, "name")
    bytes = number_field($0, "bytes")
    median = number_field($0, "median_ns")
    checksum = number_field($0, "checksum")
    key = runtime SUBSEP name

    if (runtime != "native" && runtime != "swift") {
        print "unexpected runtime: " runtime > "/dev/stderr"
        invalid = 1
    }
    if (key in checksums && checksums[key] != checksum) {
        print "checksum mismatch for " runtime "/" name > "/dev/stderr"
        invalid = 1
    }
    checksums[key] = checksum
    totals[key] += median
    counts[key] += 1
    if (!(name in seen)) {
        names[++name_count] = name
        seen[name] = 1
        fixture_bytes[name] = bytes
    } else if (fixture_bytes[name] != bytes) {
        print "fixture size mismatch for " name > "/dev/stderr"
        invalid = 1
    }
}

END {
    for (key in counts) {
        if (counts[key] != 2) {
            print "expected two passes for " key > "/dev/stderr"
            invalid = 1
        }
    }
    if (invalid) exit 2

    print "| Workload | Bytes | Native ns | Swift ns | Swift/native |"
    print "|---|---:|---:|---:|---:|"
    for (row = 1; row <= name_count; ++row) {
        name = names[row]
        native_key = "native" SUBSEP name
        swift_key = "swift" SUBSEP name
        if (counts[native_key] > 0 && counts[swift_key] > 0) {
            native = totals[native_key] / counts[native_key]
            swift = totals[swift_key] / counts[swift_key]
            printf "| `%s` | %d | %.2f | %.2f | %.2fx |\n", \
                name, fixture_bytes[name], native, swift, swift / native
        } else if (counts[swift_key] > 0) {
            swift = totals[swift_key] / counts[swift_key]
            printf "| `%s` | %d | — | %.2f | — |\n", \
                name, fixture_bytes[name], swift
        }
    }
}
