#ifndef OFFLINE_NPU_PROBE_H
#define OFFLINE_NPU_PROBE_H

#include <algorithm>
#include <cmath>
#include <fstream>
#include <functional>
#include <iomanip>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

// Fixed-input chunk0 diagnostic. No NNRT dependency: the caller supplies the
// same executor used by chat; the comparison can also be tested on the host.
namespace OfflineNpuProbe {

using Runner = std::function<bool(const std::string&, const std::vector<float>&,
                                 const std::vector<float>&, const std::vector<float>&,
                                 std::vector<float>&, std::string&)>;

inline bool safeRelativePath(const std::string& value) {
    if (value.empty() || value[0] == '/' || value.find('\\') != std::string::npos) return false;
    std::istringstream stream(value);
    std::string part;
    while (std::getline(stream, part, '/')) {
        if (part.empty() || part == "." || part == "..") return false;
    }
    return value.back() != '/';
}

inline bool safeId(const std::string& value) {
    if (value.empty()) return false;
    for (char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '_' || ch == '-')) return false;
    }
    return true;
}

inline bool readFloats(const std::string& path, std::vector<float>& values, std::string& error) {
    static_assert(sizeof(float) == 4, "Probe files require float32");
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    const std::streamoff size = stream ? static_cast<std::streamoff>(stream.tellg()) : -1;
    if (size <= 0 || size % sizeof(float) != 0 || size > 128 * 1024 * 1024) {
        error = "missing, empty or invalid float32 file: " + path;
        return false;
    }
    values.resize(static_cast<size_t>(size) / sizeof(float));
    stream.seekg(0);
    stream.read(reinterpret_cast<char*>(values.data()), size);
    if (!stream) {
        error = "cannot read: " + path;
        return false;
    }
    for (float value : values) {
        if (!std::isfinite(value)) {
            error = "non-finite value in: " + path;
            return false;
        }
    }
    return true;
}

struct Metrics {
    double cosine = 0;
    double relativeL2 = 0;
    double maxAbsError = 0;
    double referenceAbsMax = 0;
    double actualAbsMax = 0;
};

inline bool compare(const std::vector<float>& reference, const std::vector<float>& actual,
                    Metrics& metrics, std::string& error) {
    if (reference.empty() || reference.size() != actual.size()) {
        error = "output element count differs from reference";
        return false;
    }
    metrics = Metrics{};
    double dot = 0, referenceSquared = 0, actualSquared = 0, errorSquared = 0;
    for (size_t i = 0; i < actual.size(); ++i) {
        const double a = reference[i], b = actual[i], diff = a - b;
        if (!std::isfinite(a) || !std::isfinite(b)) {
            error = "non-finite reference or NPU output";
            return false;
        }
        dot += a * b;
        referenceSquared += a * a;
        actualSquared += b * b;
        errorSquared += diff * diff;
        metrics.maxAbsError = std::max(metrics.maxAbsError, std::abs(diff));
        metrics.referenceAbsMax = std::max(metrics.referenceAbsMax, std::abs(a));
        metrics.actualAbsMax = std::max(metrics.actualAbsMax, std::abs(b));
    }
    metrics.cosine = referenceSquared == 0 && actualSquared == 0 ? 1 :
        dot / std::max(std::sqrt(referenceSquared * actualSquared), 1e-30);
    metrics.relativeL2 = std::sqrt(errorSquared) / std::max(std::sqrt(referenceSquared), 1e-30);
    return true;
}

inline std::string run(const std::string& directory, const Runner& runner) {
    std::ifstream manifest(directory + "/probe.tsv");
    if (!manifest) return "ERROR: cannot open " + directory + "/probe.tsv\n";
    const std::string results = directory + "/results";
    struct stat status = {};
    if ((::stat(results.c_str(), &status) != 0 && ::mkdir(results.c_str(), 0700) != 0) ||
        ::stat(results.c_str(), &status) != 0 || !S_ISDIR(status.st_mode)) {
        return "ERROR: cannot create results directory: " + results + "\n";
    }
    std::ofstream table(results + "/report.tsv", std::ios::trunc);
    if (!table) return "ERROR: cannot write report.tsv\n";
    table << "case\tsample\texpected_ref\tstatus\tcos_float\trel_l2_float\tcos_w8a8\trel_l2_w8a8"
             "\tabsmax_actual\tabsmax_float\tabsmax_w8a8\tmax_error_float\tmax_error_w8a8\n";
    table << std::setprecision(9);
    std::ostringstream report;
    report << "W8A8 fixed-input chunk0 probe\n" << std::setprecision(7);
    size_t count = 0, aligned = 0, errors = 0;
    std::string line;
    while (std::getline(manifest, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> fields;
        std::istringstream parser(line);
        std::string field;
        while (std::getline(parser, field, '\t')) fields.push_back(field);
        bool valid = fields.size() == 9 && safeId(fields[0]) && safeId(fields[1]) &&
            (fields[8] == "float" || fields[8] == "w8a8");
        for (size_t i = 2; valid && i <= 7; ++i) valid = safeRelativePath(fields[i]);
        if (!valid) return "ERROR: invalid probe.tsv row\n" + report.str();
        ++count;
        std::vector<float> hidden, rotary, mask, floating, quantized, actual;
        std::string error;
        const bool inputsOk = readFloats(directory + "/" + fields[3], hidden, error) &&
            readFloats(directory + "/" + fields[4], rotary, error) &&
            readFloats(directory + "/" + fields[5], mask, error) &&
            readFloats(directory + "/" + fields[6], floating, error) &&
            readFloats(directory + "/" + fields[7], quantized, error);
        Metrics floatMetrics, quantMetrics;
        bool ok = inputsOk && runner(directory + "/" + fields[2], hidden, rotary, mask, actual, error);
        // Save even mismatching/non-finite outputs for subsequent host analysis.
        if (ok) {
            std::ofstream binary(results + "/" + fields[0] + "_" + fields[1] + ".bin",
                                 std::ios::binary | std::ios::trunc);
            if (!actual.empty()) binary.write(reinterpret_cast<const char*>(actual.data()), actual.size() * sizeof(float));
            if (!binary) { ok = false; error = "cannot save NPU output"; }
        }
        ok = ok && compare(floating, actual, floatMetrics, error) && compare(quantized, actual, quantMetrics, error);
        if (!ok) {
            ++errors;
            table << fields[0] << '\t' << fields[1] << '\t' << fields[8] << "\tERROR\n";
            report << fields[0] << " sample=" << fields[1] << " ERROR: " << error << '\n';
            continue;
        }
        const Metrics& expected = fields[8] == "float" ? floatMetrics : quantMetrics;
        const bool match = expected.cosine >= 0.999 && expected.relativeL2 <= 0.02;
        if (match) ++aligned;
        table << fields[0] << '\t' << fields[1] << '\t' << fields[8] << '\t'
              << (match ? "ALIGNED" : "MISMATCH") << '\t' << floatMetrics.cosine << '\t'
              << floatMetrics.relativeL2 << '\t' << quantMetrics.cosine << '\t' << quantMetrics.relativeL2
              << '\t' << floatMetrics.actualAbsMax << '\t' << floatMetrics.referenceAbsMax << '\t'
              << quantMetrics.referenceAbsMax << '\t' << floatMetrics.maxAbsError << '\t' << quantMetrics.maxAbsError << '\n';
        report << fields[0] << " sample=" << fields[1] << ' ' << (match ? "ALIGNED" : "MISMATCH")
               << " expected=" << fields[8] << "\n  vs float: cos=" << floatMetrics.cosine
               << " relL2=" << floatMetrics.relativeL2 << "\n  vs W8A8: cos=" << quantMetrics.cosine
               << " relL2=" << quantMetrics.relativeL2 << " absmax=" << quantMetrics.actualAbsMax << '\n';
    }
    if (count == 0) return "ERROR: probe.tsv has no cases\n";
    report << "Aligned " << aligned << '/' << count << ", errors=" << errors
           << "\nDiagnostic threshold: cos >= 0.999, relL2 <= 0.02 (not full-model acceptance).\n"
           << "Saved outputs and report: " << results << '\n';
    table.flush();
    if (!table) return "ERROR: cannot finish report.tsv\n" + report.str();
    std::ofstream saved(results + "/report.txt", std::ios::trunc);
    saved << report.str();
    saved.flush();
    if (!saved) return "ERROR: cannot save report.txt\n" + report.str();
    return report.str();
}

} // namespace OfflineNpuProbe
#endif
