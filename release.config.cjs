module.exports = {
  branches: ["main"],
  repositoryUrl: "https://github.com/QuartzBrowser/Quartz.git",
  tagFormat: "v${version}",
  plugins: [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/changelog",
      {
        changelogFile: "CHANGELOG.md",
      },
    ],
    [
      "@semantic-release/exec",
      {
        prepareCmd: [
          "Scripts/prepare-release.sh '${nextRelease.version}'",
          "printf '%s\\n' '${nextRelease.version}' > version.txt",
        ].join(" && "),
      },
    ],
    [
      "@semantic-release/git",
      {
        assets: ["CHANGELOG.md", "version.txt"],
        message: "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}",
      },
    ],
    [
      "@semantic-release/github",
      {
        successComment: false,
        failComment: false,
        assets: [
          {
            // Asset paths are globs, not templates. A templated path silently
            // published releases without a downloadable application.
            path: "dist/release/Quartz-v*-macos-universal.zip",
            label: "Quartz ${nextRelease.gitTag} macOS universal app",
          },
          { path: "dist/release/appcast.xml", label: "Signed Quartz update feed" },
          { path: "dist/release/SHA256SUMS", label: "Release checksums" },
        ],
      },
    ],
  ],
};
