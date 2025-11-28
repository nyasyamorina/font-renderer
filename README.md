# A Simple Font Renderer

Rendering glyph based on triangulation.

---

### Source code overview (and where the code is)

- reading font info from `.ttf` file ([font/ttf.zig](./src/font/ttf.zig), [font/Font.zig](./src/font/Font.zig))

- parsing glyph data in `.ttf` file ([font/ttf.zig](./src/font/ttf.zig), [font/Glyph.zig](./src/font/Glyph.zig))

- glyph triangulation ([tools/TriangulatedGlyph.zig](./src/tools/TriangulatedGlyph.zig), [tools/geometry.zig](./src/tools/geometry.zig))

- rendering the triangulated glyph ([Appli.zig](./src/Appli.zig), [shaders/shader.slang](./src/shaders/shader.slang))

- vulkan stuff ([VulkanContext.zig](./src/VulkanContext.zig), [CacheManager.zig](./src/CacheManager.zig))

- user input ([CallbackContext.zig](./src/CallbackContext.zig), [Appli.zig](./src/Appli.zig), [VulkanContext.zig](./src/VulkanContext.zig))

- simple command line args parser ([Config.zig](./src/Config.zig))

- c wrapper ([c/glfw.zig](./src/c/glfw.zig), [vk.zig](./src/c/vk.zig))

- some tools that currently not using: image interface ([tools/Image.zig](./src/tools/Image.zig)), save RGB image into `.qoi` format ([tools/qoi.zig](./src/tools/qoi.zig)), wrong implementation of glyph rendering based on winding number ([tools/render_glyph.zig](./src/tools/render_glyph.zig))

---

### Build

1. since this is a zig project, you need a [zig compiler](https://ziglang.org/download/), and this project is written in zig 0.15.2

2. ensure [Vulkan SDK](https://vulkan.lunarg.com/) is in your machine, and set the enviroment variable `VULKAN_SDK` to it

3. ensure glfw dependency is installed, that means:

    - for linux user, need to install glfw3 in your system

    - for windows user, doing nothing should be enough, the build script will automatically copy [glfw-3.4/lib/glfw3.dll](./third-party/glfw-3.4/lib/glfw3.dll) into build output directory

    - for mac user, send me a mac machine

4. run `zig build`, the build output is "./zig-out/bin/font-renderer"

---

### Command line arguments

- `-f/--font_file <ttf file>`: the path to `.ttf` font file

- `-t/--text <utf8 string>`: the text you want to render

- `-c/--cache`: enable pipeline caching

---

### Keybinds

- `<esc>`: close the window and exit

- `<ctrl>+M`: toggle the MSAA rendering

---

### TODO

- use `<ctrl>+T` to toggle the transparent background

- user text input and deletion

- line breaking

- fix wrong glyph triangulation
