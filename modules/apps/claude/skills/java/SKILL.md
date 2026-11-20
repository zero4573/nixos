---
name: java
description: Building, testing and running Java (Maven, Gradle, ./mvnw, ./gradlew, a Maven or Gradle step inside podman build) in this machine's sandbox, where private artifacts come through a local registry proxy, plus where the JDK comes from and the Java language server. Use it before running mvn, mvnw, gradle or gradlew, when a Java build fails to resolve or download something (PKIX, "unable to find valid certification path", 401, "Could not transfer artifact", a wrapper download that fails), or when a Dockerfile builds Java. For how to write the code itself, a tix ticket session reads tix:practices (java.md).
---

# Java in the sandbox

## How the network is laid out
- `streamsix.jfrog.io` (Artifactory: the company's own libraries and its
  mirrors of Maven Central and JBoss) resolves to a local proxy in the
  sandbox. Over https it serves a certificate the JVM doesn't trust, so a JVM
  talking to `https://streamsix.jfrog.io` fails with PKIX / "unable to find
  valid certification path". The working route is plain HTTP to
  `http://registry-proxy:7080/artifactory/<repo>/`, which adds the credential
  itself: no credential is in the sandbox, and none is needed in any file.
- Public hosts (Maven Central, the Gradle plugin portal, services.gradle.org)
  are reachable directly.
- Never work around TLS: no `-Dmaven.wagon.http.ssl.insecure`, no
  `-Djavax.net.ssl.trustStore` with the proxy's CA, no `keytool -import`, no
  credentials in `settings.xml`, `gradle.properties` or the environment.

## Maven
- `~/.m2/settings.xml` is provided (read-only): a mirror of every repository
  (`mirrorOf *`) to `http://registry-proxy:7080/artifactory/java-virtual/`. Plain
  `mvn` / `./mvnw` picks it up; check with `mvn help:effective-settings` (the
  `sandbox-proxy` mirror). There is no settings file when the proxy isn't set
  up: then say so to the user rather than editing one in.
- A project that passes its own settings (`-s ci/settings.xml` in
  `.mvn/maven.config` or a script) replaces the user settings: add
  `-s ~/.m2/settings.xml` to your command line instead of editing the
  project's file. Its `<servers>` credentials aren't needed.
- `./mvnw` downloads Maven itself through the proxy (`MVNW_REPOURL` is set).
- `~/.m2/repository` lives as long as the sandbox: the first build downloads
  everything. Use `-o` (offline) for repeated runs once it has.
- No `mvn` on PATH: use the project's `./mvnw`; without one, ask the user.

## Gradle
- `~/.gradle/init.d/sandbox-proxy.gradle` (read-only) points every repository
  whose host is `streamsix.jfrog.io` at the proxy over HTTP, in settings
  (plugin management, dependency resolution management) and in projects.
  Public repositories stay as they are. The repository's own credentials
  block can stay; the proxy replaces them.
- `./gradlew` downloads its distribution from services.gradle.org directly.
- Run with `--no-daemon` in short-lived sessions, and `--offline` once the
  caches are warm.

## The JDK
The JDK comes from asdf on the host (read-only in the sandbox): the
project's `.tool-versions` line `java <version>` (e.g. `java temurin-21.0.5+11.0.LTS`),
else the user's default. `java -version` shows which. A version that isn't
installed fails with "No preset version installed": ask the user to run
`asdf install java <version>` on the host; you can't install it. A Gradle
toolchain that would download a JDK is pointed at the asdf one instead:
`-Porg.gradle.java.installations.paths="$(asdf where java)"
-Porg.gradle.java.installations.auto-download=false`.

## Inside podman build
A container built in the sandbox reaches the proxy too (`registry-proxy`
resolves in it). Give the build's `RUN` steps the same configuration with
volumes, not by editing the Dockerfile:

```sh
podman build \
  -v "$HOME/.m2/settings.xml:/root/.m2/settings.xml:ro" \
  -v "$HOME/.gradle/init.d:/root/.gradle/init.d:ro" \
  -t <name> .
```

- Paths are for an image that builds as root (the official `maven`,
  `gradle` and `eclipse-temurin` images); for a `USER` with another home, mount
  at that home's `.m2` / `.gradle`, or pass `-s /path/settings.xml` in the
  Dockerfile's command when it already takes arguments.
- Add `-v "$HOME/.m2/repository:/root/.m2/repository"` to reuse the
  sandbox's downloads across builds.
- Base images come through the registry mirror too: pin them by tag or
  digest (a floating tag can fail with "manifest unknown").

## Tests
Unit tests run as usual. Testcontainers needs a Docker API: run
`podman system service -t 0 unix:///tmp/podman.sock &`, then
`DOCKER_HOST=unix:///tmp/podman.sock TESTCONTAINERS_RYUK_DISABLED=true`
for the test command.

## Code navigation
The LSP tool covers `.java` (jdtls, see the `lsp` skill). It imports the
Maven or Gradle build first, so it needs the dependencies reachable as above.
