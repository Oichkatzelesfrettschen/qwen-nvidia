// Holds the paged KV residency engine to its transaction contract with a
// mocked driver: commit order per unit, unwind of a commit that fails halfway,
// quiescence ahead of the first unmap, tails-only release under a contiguous
// requirement, zero-initialization of a recommitted unit, and the five
// accounting quantities through every path. The engine is the header the
// patch carries; scripts/test-paged-kv-residency-transactions.sh extracts it
// from patches/llama-cuda-paged-kv-buffer.patch and compiles this file
// against it, so the test reads the bytes the closure builds from.

#include "paged-kv-residency.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

namespace {

struct mock_driver {
    // Every call is appended as "op:unit" so a test asserts order.
    std::vector<std::string> calls;
    // Fail the Nth call of an op (1-based) with this status.
    std::string fail_op;
    int fail_at = 0;
    int fail_status = 0;
    std::map<std::string, int> op_counts;
    // Live handles and mappings, as the driver would hold them.
    std::map<uint64_t, bool> live_handles;
    std::map<size_t, uint64_t> mapped_units;
    std::map<size_t, int> zero_count;
    uint64_t next_handle = 100;

    int call(const std::string & op, size_t unit) {
        char line[64];
        std::snprintf(line, sizeof(line), "%s:%zu", op.c_str(), unit);
        calls.push_back(line);
        const int n = ++op_counts[op];
        if (op == fail_op && n == fail_at) {
            return fail_status;
        }
        return 0;
    }
};

int drv_create(void * user, size_t unit, uint64_t * handle) {
    auto * d = (mock_driver *) user;
    const int status = d->call("create", unit);
    if (status != 0) {
        *handle = 0;
        return status;
    }
    *handle = d->next_handle++;
    d->live_handles[*handle] = true;
    return 0;
}

int drv_map(void * user, size_t unit, uint64_t handle) {
    auto * d = (mock_driver *) user;
    const int status = d->call("map", unit);
    if (status != 0) {
        return status;
    }
    if (!d->live_handles.count(handle) || d->mapped_units.count(unit)) {
        std::fprintf(stderr, "mock: map of a dead handle or a mapped unit %zu\n", unit);
        std::abort();
    }
    d->mapped_units[unit] = handle;
    return 0;
}

int drv_set_access(void * user, size_t unit) {
    auto * d = (mock_driver *) user;
    const int status = d->call("set_access", unit);
    if (status == 0 && !d->mapped_units.count(unit)) {
        std::fprintf(stderr, "mock: access on an unmapped unit %zu\n", unit);
        std::abort();
    }
    return status;
}

int drv_zero(void * user, size_t unit) {
    auto * d = (mock_driver *) user;
    const int status = d->call("zero", unit);
    if (status == 0) {
        d->zero_count[unit] += 1;
    }
    return status;
}

int drv_quiesce(void * user) {
    auto * d = (mock_driver *) user;
    return d->call("quiesce", 0);
}

int drv_unmap(void * user, size_t unit) {
    auto * d = (mock_driver *) user;
    const int status = d->call("unmap", unit);
    if (status != 0) {
        return status;
    }
    if (!d->mapped_units.count(unit)) {
        std::fprintf(stderr, "mock: unmap of an unmapped unit %zu\n", unit);
        std::abort();
    }
    d->mapped_units.erase(unit);
    return 0;
}

int drv_release(void * user, uint64_t handle) {
    auto * d = (mock_driver *) user;
    const int status = d->call("release", (size_t) handle);
    if (status != 0) {
        return status;
    }
    if (!d->live_handles.count(handle)) {
        std::fprintf(stderr, "mock: release of a dead handle %llu\n", (unsigned long long) handle);
        std::abort();
    }
    for (const auto & [unit, h] : d->mapped_units) {
        if (h == handle) {
            std::fprintf(stderr, "mock: release of a handle still mapped at unit %zu\n", unit);
            std::abort();
        }
    }
    d->live_handles.erase(handle);
    return 0;
}

ggml_paged_kv_driver driver_for(mock_driver & d) {
    ggml_paged_kv_driver drv;
    drv.user = &d;
    drv.create = drv_create;
    drv.map = drv_map;
    drv.set_access = drv_set_access;
    drv.zero = drv_zero;
    drv.quiesce = drv_quiesce;
    drv.unmap = drv_unmap;
    drv.release = drv_release;
    return drv;
}

int failures = 0;

void check(bool ok, const char * what) {
    std::printf("%s\t%s\n", ok ? "ok" : "FAIL", what);
    if (!ok) {
        failures += 1;
    }
}

const size_t G = 2097152; // the measured minimum granularity, stated here as the layout the checks use

// The served 2B layout: K rows of 544 bytes and V rows of 288 bytes over
// 65536 cells, one stream, six attention layers. Twelve tensors, each
// padded to the unit, in K, V order per layer.
struct tensor_layout {
    size_t offset;
    size_t row_bytes;
};

std::vector<tensor_layout> layout_2b(size_t & total) {
    std::vector<tensor_layout> t;
    size_t offset = 0;
    for (int layer = 0; layer < 6; ++layer) {
        for (size_t row : {(size_t) 544, (size_t) 288}) {
            t.push_back({offset, row});
            const size_t bytes = row * 65536;
            offset += (bytes + G - 1) / G * G;
        }
    }
    total = offset;
    return t;
}

size_t backing_for_rows(size_t rows) {
    size_t total = 0;
    const auto t = layout_2b(total);
    ggml_paged_kv_residency r(G, total);
    std::vector<bool> required;
    for (const auto & tl : t) {
        r.require(required, tl.offset, rows * tl.row_bytes);
    }
    size_t units = 0;
    for (bool b : required) {
        units += b ? 1 : 0;
    }
    return units * G;
}

} // namespace

int main() {
    // units([a, b)) arithmetic on the contract's own examples.
    {
        size_t first = 0;
        size_t last_p1 = 0;
        check(ggml_paged_kv_residency::units_of(G, 0, 1, first, last_p1) && first == 0 && last_p1 == 1, "units_of one byte at offset 0 names unit 0");
        check(ggml_paged_kv_residency::units_of(G, G - 1, 2, first, last_p1) && first == 0 && last_p1 == 2, "units_of a row crossing a boundary names both units");
        check(ggml_paged_kv_residency::units_of(G, G, G, first, last_p1) && first == 1 && last_p1 == 2, "units_of one exact unit names it alone");
        check(!ggml_paged_kv_residency::units_of(G, 5, 0, first, last_p1) && last_p1 == 0, "units_of an empty interval names no unit");
    }

    // The contract's backing table, M(h) = 6G(ceil(544h/G) + ceil(288h/G)).
    check(backing_for_rows(4096) == 36u * 1048576u, "M(4096) reads 36 MiB");
    check(backing_for_rows(32768) == 168u * 1048576u, "M(32768) reads 168 MiB");
    check(backing_for_rows(65536) == 312u * 1048576u, "M(65536) reads 312 MiB");
    check(backing_for_rows(256) == 24u * 1048576u, "the 256-row minimum envelope costs 24 MiB");
    check(backing_for_rows(3855) == 24u * 1048576u && backing_for_rows(3856) == 36u * 1048576u,
          "the first K unit grows at row 3856, where 544 bytes per row cross the unit, 6 tensors at once");

    // Commit order per unit and accounting on a fresh sparse buffer.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 8 * G);
        std::vector<bool> req;
        r.require(req, 0, 3 * G + 1); // units 0..3
        auto tx = r.commit(req, drv);
        check(tx.ok && tx.units_committed == 4, "commit backs the four required units");
        {
            std::vector<std::string> expected;
            for (size_t u = 0; u < 4; ++u) {
                for (const char * op : {"create", "map", "set_access", "zero"}) {
                    expected.push_back(std::string(op) + ":" + std::to_string(u));
                }
            }
            check(d.calls == expected, "every unit runs create, map, set_access, zero in that order, unit by unit");
        }
        const auto & a = r.accounting();
        check(a.virtual_reserved_bytes == 8 * G && a.physical_allocated_bytes == 4 * G && a.physical_mapped_bytes == 4 * G
              && a.physical_retained_unmapped_bytes == 0 && a.physical_released_bytes == 0,
              "accounting after commit: allocated equals mapped equals four units");
        check(r.resident(0, 3 * G + 1) && !r.resident(0, 4 * G + 1), "resident() reads the committed extent and nothing past it");
        // A second commit of the same set is a no-op with no driver call.
        const size_t calls_before = d.calls.size();
        tx = r.commit(req, drv);
        check(tx.ok && tx.units_committed == 0 && d.calls.size() == calls_before, "a commit inside the resident set makes no driver call");
        // Reclaim with nothing to release makes no quiesce call.
        tx = r.reclaim(req, drv);
        check(tx.ok && tx.units_released == 0 && d.calls.size() == calls_before, "a reclaim that releases nothing quiesces nothing");
    }

    // A commit failing halfway unwinds the units it created and leaves the prior set.
    for (const char * step : {"create", "map", "set_access", "zero"}) {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 8 * G);
        std::vector<bool> req;
        r.require(req, 0, 2 * G); // units 0, 1
        check(r.commit(req, drv).ok, "baseline commit of two units");
        const auto before = r.accounting();
        d.calls.clear();
        d.op_counts.clear();
        d.fail_op = step;
        d.fail_at = 3; // the third unit of this transaction: units 2, 3 succeed, 4 fails
        d.fail_status = 2;
        std::vector<bool> req2;
        r.require(req2, 0, 7 * G); // units 0..6
        auto tx = r.commit(req2, drv);
        std::string what = std::string("commit failing at ") + step + " unwinds the units it created";
        check(!tx.ok && tx.step == std::string(step) && tx.unit_index == 4 && tx.status == 2 && tx.units_committed == 0, what.c_str());
        // The unwind runs newest unit first: the failed unit 4 (released,
        // and unmapped first where its map succeeded), then 3, then 2, each
        // as unmap then release, and nothing touches units 0 and 1.
        {
            std::vector<std::string> tail;
            bool seen_failure = false;
            for (const auto & c : d.calls) {
                if (seen_failure) {
                    tail.push_back(c);
                } else if (c == std::string(step) + ":4") {
                    seen_failure = true;
                }
            }
            std::vector<std::string> expected;
            const bool unit4_mapped = std::string(step) != "create" && std::string(step) != "map";
            if (std::string(step) != "create") {
                if (unit4_mapped) {
                    expected.push_back("unmap:4");
                }
                expected.push_back("release:" + std::to_string(100 + 2 + 2)); // the third handle this transaction created
            }
            for (size_t u : {(size_t) 3, (size_t) 2}) {
                expected.push_back("unmap:" + std::to_string(u));
                expected.push_back("release:" + std::to_string(100 + u));
            }
            check(tail == expected, "  the unwind runs newest first, unmap then release per unit, touching no prior unit");
        }
        const auto after = r.accounting();
        check(after.physical_allocated_bytes == before.physical_allocated_bytes && after.physical_mapped_bytes == before.physical_mapped_bytes,
              "  allocated and mapped return to the prior set");
        check(r.resident(0, 2 * G) && !r.unit_published(2) && !r.unit_published(3) && !r.unit_published(4),
              "  the prior set stays resident and the transaction's units are unpublished");
        check(d.mapped_units.size() == 2 && d.live_handles.size() == 2, "  the mock holds two mappings and two handles");
        const size_t unwound_expected = std::string(step) == "create" ? 2 : 3;
        check(tx.units_unwound == unwound_expected, "  the count of unwound units matches the step reached");
        check(after.physical_released_bytes == before.physical_released_bytes + unwound_expected * G,
              "  the unwound handles are counted as released");
    }

    // A release the driver refuses keeps the handle with the unit, counts it
    // as retained unmapped, and the next commit of that unit retries the
    // release ahead of any new allocation, so no handle is overwritten.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 4 * G);
        std::vector<bool> req;
        r.require(req, 0, 3 * G);
        check(r.commit(req, drv).ok, "three units committed ahead of the refused release");
        d.op_counts.clear();
        d.fail_op = "release";
        d.fail_at = 1;
        d.fail_status = 11;
        std::vector<bool> req2;
        r.require(req2, 0, G);
        auto tx = r.reclaim(req2, drv);
        check(!tx.ok && tx.step == std::string("release") && tx.unit_index == 1 && tx.units_released == 0,
              "a refused release ends the reclaim on that unit with nothing released");
        const auto & a = r.accounting();
        check(a.physical_allocated_bytes == 3 * G && a.physical_mapped_bytes == 2 * G && a.physical_retained_unmapped_bytes == G
              && a.physical_released_bytes == 0 && !r.unit_published(1),
              "  the unit is unmapped, held, and counted as retained unmapped");
        check(d.live_handles.size() == 3 && d.mapped_units.size() == 2, "  the mock holds three handles and two mappings");
        d.fail_op.clear();
        d.calls.clear();
        std::vector<bool> req3;
        r.require(req3, 0, 3 * G);
        tx = r.commit(req3, drv);
        // Unit 2 stayed published, since the reclaim stopped at unit 1, so
        // the commit recommits the held unit alone.
        check(tx.ok && tx.units_committed == 1 && d.calls[0] == "release:101" && d.calls[1] == "create:1",
              "the next commit of the held unit releases its handle ahead of creating another");
        check(r.accounting().physical_retained_unmapped_bytes == 0 && r.accounting().physical_released_bytes == G
              && r.accounting().physical_allocated_bytes == 3 * G && d.live_handles.size() == 3,
              "  retained returns to zero, released counts the retried handle, and the mock holds three handles");
        // A retry the driver refuses again refuses the commit, and the units
        // the transaction created beside it unwind.
        d.op_counts.clear();
        d.fail_op = "release";
        d.fail_at = 1;
        d.fail_status = 12;
        std::vector<bool> req4;
        r.require(req4, 0, G);
        tx = r.reclaim(req4, drv);
        check(!tx.ok && r.accounting().physical_retained_unmapped_bytes == G && r.published_count() == 2, "(setup) one unit held after a refused release");
        d.op_counts.clear();
        d.fail_status = 13;
        std::vector<bool> req5;
        r.require(req5, 0, 4 * G);
        tx = r.commit(req5, drv);
        check(!tx.ok && tx.step == std::string("release") && tx.status == 13 && r.published_count() == 2
              && r.accounting().physical_retained_unmapped_bytes == G,
              "a retried release refused again refuses the commit and leaves the prior set and the held unit");
        d.fail_op.clear();
        tx = r.destroy(drv);
        check(tx.ok && d.live_handles.empty() && d.mapped_units.empty(), "destroy releases the held handles too");
    }

    // An unwind whose releases are refused reports the units it could not
    // return, and the accounting keeps them as held.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 4 * G);
        d.fail_op = "map";
        d.fail_at = 2;
        d.fail_status = 3;
        std::vector<bool> req;
        r.require(req, 0, 2 * G);
        auto tx = r.commit(req, drv);
        check(!tx.ok && tx.step == std::string("map") && tx.units_unwound == 2 && tx.units_unwind_failed == 0,
              "(control) an unwind whose releases succeed reports both units unwound");

        mock_driver d2;
        auto drv2 = driver_for(d2);
        ggml_paged_kv_residency r2(G, 4 * G);
        d2.fail_op = "map";
        d2.fail_at = 2;
        d2.fail_status = 3;
        drv2.release = [](void * user, uint64_t handle) -> int {
            auto * m = (mock_driver *) user;
            m->call("release", (size_t) handle);
            return 5; // every release refused
        };
        std::vector<bool> req2;
        r2.require(req2, 0, 2 * G);
        tx = r2.commit(req2, drv2);
        check(!tx.ok && tx.step == std::string("map") && tx.units_unwound == 0 && tx.units_unwind_failed == 2,
              "an unwind whose releases are refused reports both units as unwind failures");
        check(r2.accounting().physical_allocated_bytes == 2 * G && r2.accounting().physical_mapped_bytes == 0
              && r2.accounting().physical_retained_unmapped_bytes == 2 * G && r2.published_count() == 0,
              "  both handles stay held and counted as retained unmapped");
    }

    // Reclaim: quiesce once, then unmap and release each tail unit; the
    // interior stays because the requirement is contiguous from 0.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 8 * G);
        std::vector<bool> req;
        r.require(req, 0, 6 * G);
        check(r.commit(req, drv).ok && r.published_count() == 6, "six units committed");
        d.calls.clear();
        std::vector<bool> req2;
        r.require(req2, 0, 2 * G + 5); // units 0..2
        auto tx = r.reclaim(req2, drv);
        check(tx.ok && tx.units_released == 3, "reclaim releases the three tail units");
        check(d.calls[0] == "quiesce:0" && d.calls[1] == "unmap:3", "quiesce runs once ahead of the first unmap");
        int quiesce_calls = 0;
        for (const auto & c : d.calls) {
            quiesce_calls += c == "quiesce:0" ? 1 : 0;
        }
        check(quiesce_calls == 1, "one quiesce per reclaim transaction");
        const auto & a = r.accounting();
        check(a.physical_allocated_bytes == 3 * G && a.physical_mapped_bytes == 3 * G && a.physical_retained_unmapped_bytes == 0
              && a.physical_released_bytes == 3 * G, "accounting after reclaim: three held, three released, none retained");
        check(d.mapped_units.size() == 3 && d.live_handles.size() == 3, "the mock holds three mappings and three handles");

        // Regrowth recommits and zeroes the reused extent.
        d.calls.clear();
        std::vector<bool> req3;
        r.require(req3, 0, 5 * G);
        tx = r.commit(req3, drv);
        check(tx.ok && tx.units_committed == 2 && d.zero_count[3] == 2 && d.zero_count[4] == 2, "regrowth recommits and zeroes units 3 and 4 again");
        check(r.accounting().physical_allocated_bytes == 5 * G && r.accounting().physical_released_bytes == 3 * G,
              "regrowth raises allocated and leaves released cumulative");

        // A quiesce failure releases nothing.
        d.calls.clear();
        d.op_counts.clear();
        d.fail_op = "quiesce";
        d.fail_at = 1;
        d.fail_status = 7;
        std::vector<bool> req4;
        r.require(req4, 0, G);
        tx = r.reclaim(req4, drv);
        check(!tx.ok && tx.step == std::string("quiesce") && tx.units_released == 0 && r.published_count() == 5,
              "a failed quiesce leaves every unit backed");
        d.fail_op.clear();

        // An unmap failure stops the reclaim with the failed unit still backed.
        d.calls.clear();
        d.op_counts.clear();
        d.fail_op = "unmap";
        d.fail_at = 2;
        d.fail_status = 9;
        tx = r.reclaim(req4, drv);
        check(!tx.ok && tx.step == std::string("unmap") && tx.units_released == 1 && r.published_count() == 4 && r.unit_published(2),
              "a failed unmap ends the reclaim with that unit still published");
        d.fail_op.clear();

        // Destroy releases everything that remains.
        tx = r.destroy(drv);
        check(tx.ok && r.published_count() == 0 && d.mapped_units.empty() && d.live_handles.empty(), "destroy unmaps and releases every unit");
        check(r.accounting().physical_allocated_bytes == 0 && r.accounting().physical_mapped_bytes == 0, "accounting after destroy reads zero held");
    }

    // A shared unit survives while one interval still requires it; a
    // requirement outside the reservation is refused.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 4 * G);
        std::vector<bool> req;
        r.require(req, 0, G + 10);      // tensor A: units 0, 1
        r.require(req, G + 10, G - 10); // tensor B: unit 1
        check(r.commit(req, drv).ok && r.published_count() == 2, "two intervals sharing unit 1 commit two units");
        std::vector<bool> req2;
        r.require(req2, G + 10, G - 10); // A released, B still holds unit 1
        auto tx = r.reclaim(req2, drv);
        check(tx.ok && tx.units_released == 1 && r.unit_published(1) && !r.unit_published(0), "unit 1 survives while B requires it; unit 0 is released");
        std::vector<bool> req3;
        check(!r.require(req3, 3 * G, 2 * G), "an interval past the reservation is refused");
        check(r.require(req3, 4 * G, 0), "an empty interval at the end is accepted");
    }

    // Resident runs for a memset over a sparse buffer touch published bytes alone.
    {
        mock_driver d;
        auto drv = driver_for(d);
        ggml_paged_kv_residency r(G, 6 * G);
        std::vector<bool> req;
        r.require(req, 0, G);
        r.require(req, 2 * G, G);
        r.require(req, 3 * G, G);
        r.commit(req, drv);
        std::vector<std::pair<size_t, size_t>> runs;
        r.for_each_resident_run(10, 6 * G - 20, [&](size_t off, size_t size) { runs.emplace_back(off, size); });
        check(runs.size() == 2 && runs[0].first == 10 && runs[0].second == G - 10 && runs[1].first == 2 * G && runs[1].second == 2 * G,
              "resident runs split at the hole and clip to the interval");
    }

    std::printf("residency_transactions=%s failures=%d\n", failures == 0 ? "passed" : "failed", failures);
    return failures == 0 ? 0 : 1;
}
