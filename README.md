# Spotify HUD Remastered

Spotify HUD Remastered is a client-side Fabric mod for Minecraft that adds a clean, configurable now-playing display directly to the game.

It is designed to show desktop media information in a lightweight HUD while keeping the controls and configuration inside Minecraft.

## Features

- Shows the currently playing track in-game
- Displays media status and playback information
- Includes media controls when supported by the operating system
- Configurable HUD position, layout, font, theme, and appearance
- In-game HUD editor
- Mod Menu integration
- Media diagnostics to help troubleshoot detection problems
- Cross-platform helper support for Windows, Linux, and macOS
- Client-side only, so it does not need to be installed on the server

## Supported Version

This release targets:

- Minecraft **1.21.11**
- Fabric Loader **0.17.3 or newer**
- Fabric API **0.139.5+1.21.11 or newer**
- Java **21 or newer**
- Mod Menu **17.0.0+** is optional but recommended

## Project Structure

The main source packages are organized like this:

```text
io.github.spotifyhud.client
├── config        # HUD settings and configuration
├── integration   # Mod Menu integration
├── media         # Media detection, playback state, and controls
├── render        # HUD rendering and color utilities
└── screen        # Configuration and HUD editor screens
```

Runtime resources are stored under:

```text
src/main/resources/
├── assets/spotifyhud/
│   ├── font/
│   ├── lang/
│   └── icon.png
├── spotifyhud/helpers/
└── fabric.mod.json
```

The helper scripts are used for platform-specific media integration:

- `spotify-media-windows.ps1`
- `spotify-media-linux.sh`
- `spotify-media-macos.sh`

## Building From Source

### Requirements

Before building, install:

1. **JDK 21**
2. **Git**
3. A recent version of Gradle is not required if the repository contains the Gradle Wrapper.

You can check your Java version with:

```bash
java -version
```

It should report Java 21 or newer.

### Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/spotify-hud.git
cd spotify-hud
```

Replace `YOUR_USERNAME` with the GitHub account that hosts the project.

### Build on Windows

Open PowerShell or Command Prompt in the project folder and run:

```powershell
.\gradlew.bat build
```

### Build on Linux or macOS

Give the Gradle wrapper permission to run if necessary:

```bash
chmod +x gradlew
```

Then build:

```bash
./gradlew build
```

### Build Output

After a successful build, the compiled mod JAR should be located in:

```text
build/libs/
```

Use the normal release JAR from that folder. Do not distribute development, sources, or intermediary JARs unless you specifically need them.

## Running in a Development Environment

To launch a development Minecraft client:

### Windows

```powershell
.\gradlew.bat runClient
```

### Linux / macOS

```bash
./gradlew runClient
```

This launches Minecraft using the development environment configured by Fabric Loom.

## Opening the Project in IntelliJ IDEA

1. Clone or extract the source repository.
2. Open IntelliJ IDEA.
3. Select **Open** and choose the project folder.
4. Allow IntelliJ to import the Gradle project.
5. Make sure the project SDK is set to **Java 21**.
6. Wait for Gradle and Minecraft dependencies to finish downloading.
7. Use the Gradle `runClient` task to test the mod.

## Installing a Built Version

1. Install Fabric Loader for Minecraft 1.21.11.
2. Install Fabric API.
3. Optionally install Mod Menu.
4. Place the built Spotify HUD JAR in your Minecraft `mods` folder.
5. Start Minecraft with the Fabric profile.

## Configuration

Spotify HUD stores its settings through the mod's configuration system.

The available settings include HUD placement and appearance options such as:

- Anchor and position
- Layout
- Font
- Theme
- Media mode
- HUD styling

When Mod Menu is installed, the configuration screen can be opened from the Mods menu.

## Platform Integration

Spotify HUD uses operating-system media information rather than requiring the mod to modify Spotify itself.

The project contains separate helper scripts for Windows, Linux, and macOS. Their availability and supported playback controls can vary depending on the operating system, desktop environment, and media player.

Although the project is named Spotify HUD, the underlying media detection may work with other applications that expose compatible system media information.

## Privacy

The mod is intended to read the media information needed to display the currently playing track and provide supported playback controls.

It should not require passwords or a Spotify account password to be stored in the source code.

Never commit secrets, tokens, private credentials, personal configuration files, or API keys to the repository.

A source repository should normally ignore files such as:

```text
.env
*.key
*.pem
.idea/
.vscode/
.gradle/
build/
run/
```

## Contributing

Bug reports and pull requests are welcome.

When making changes:

1. Create a new branch.
2. Make and test your changes.
3. Run a full Gradle build.
4. Make sure no secrets or local files are included.
5. Open a pull request describing what changed.

## License

Spotify HUD Remastered is licensed under the **MIT License**.

See the included license file for the full license text.

## Disclaimer

Spotify HUD Remastered is an independent Minecraft mod. It is not affiliated with, sponsored by, or endorsed by Spotify or Mojang Studios.

Spotify and the Spotify logo are trademarks of Spotify AB. Minecraft is a trademark of Microsoft/Mojang Studios.

---

### Note About Decompiled or Unpacked JARs

An unpacked release JAR is **not the same thing as a complete source repository**.

A release JAR normally contains compiled `.class` files and runtime resources, but it does not normally contain the original `.java` source files, `build.gradle`, `gradle.properties`, Gradle wrapper, or other files required to rebuild the project.

To make this repository genuinely buildable from source, publish the original development project containing the Java source and Gradle build files rather than only the contents extracted from the compiled JAR.
