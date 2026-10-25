/// How a build names its version. From 0.38 a build is a version of its
/// own, MAJOR.MINOR.BUILD ("0.38.7", its build number always 1), and the
/// version says it all; before, a version and a build ("0.35 (21)").
public enum VersionTitle {
    public static func of(version: String, build: String?) -> String {
        guard let build, !build.isEmpty, version.split(separator: ".").count < 3 else { return version }
        return "\(version) (\(build))"
    }
}
