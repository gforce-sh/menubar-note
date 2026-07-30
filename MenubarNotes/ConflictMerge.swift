import Foundation

enum ConflictMerge {
    /// Combines both versions into a single body, since the design keeps one
    /// remote note and neither side may silently lose work. The merged text
    /// becomes the new content on both sides, markers included, until the user
    /// cleans it up by hand.
    static func merge(
        local: String,
        localDate: Date,
        remote: String,
        remoteDate: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        return """
        <<<<<<< local (\(formatter.string(from: localDate)))
        \(local)
        =======
        \(remote)
        >>>>>>> remote (\(formatter.string(from: remoteDate)))
        """
    }
}
