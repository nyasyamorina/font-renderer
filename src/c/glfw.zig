const c = @import("c.zig").c;

pub const client_api = c.GLFW_CLIENT_API;
pub const no_api = c.GLFW_NO_API;
pub const resizable = c.GLFW_RESIZABLE;
pub const transparent_framebuffer = c.GLFW_TRANSPARENT_FRAMEBUFFER;
pub const cursor = c.GLFW_CURSOR;
pub const cursor_normal = c.GLFW_CURSOR_NORMAL;
pub const pointing_hand_cursor = c.GLFW_POINTING_HAND_CURSOR;
pub const arrow_cursor = c.GLFW_ARROW_CURSOR;
pub const @"false" = c.GLFW_FALSE;
pub const @"true" = c.GLFW_TRUE;

pub const MouseBotton = enum(c_int) {
    left = c.GLFW_MOUSE_BUTTON_LEFT,
    right = c.GLFW_MOUSE_BUTTON_RIGHT,
    _,
};
pub const Action = enum(c_int) {
    press = c.GLFW_PRESS,
    release = c.GLFW_RELEASE,
    repeat = c.GLFW_REPEAT,
    _,
};
pub const Key = enum(c_int) {
    escape = c.GLFW_KEY_ESCAPE,
    backspace = c.GLFW_KEY_BACKSPACE,
    m = c.GLFW_KEY_M,
    _,
};
pub const Mods = packed struct(c_int) {
    shift: bool,
    control: bool,
    alt: bool,
    super: bool,
    caps_lock: bool,
    num_lock: bool,
    _pad: u26,
};

pub const Window = c.GLFWwindow;
pub const Cursor = c.GLFWcursor;

pub const init = c.glfwInit;
pub const windowHint = c.glfwWindowHint;
pub const createWindow = c.glfwCreateWindow;
pub const createStandardCursor = c.glfwCreateStandardCursor;
pub const windowShouldClose = c.glfwWindowShouldClose;
pub const setWindowShouldClose = c.glfwSetWindowShouldClose;
pub const pollEvents = c.glfwPollEvents;
pub const destroyWindow = c.glfwDestroyWindow;
pub const destroyCursor = c.glfwDestroyCursor;
pub const terminate = c.glfwTerminate;
pub const getRequiresInstanceExtensions = c.glfwGetRequiredInstanceExtensions;
pub const createWindowSurface = c.glfwCreateWindowSurface;
pub const getFramebufferSize = c.glfwGetFramebufferSize;
pub const getCursorPos = c.glfwGetCursorPos;
pub const setCursor = c.glfwSetCursor;
pub const setInputMode = c.glfwSetInputMode;
pub const setWindowUserPointer = c.glfwSetWindowUserPointer;
pub const setFramebufferSizeCallback = c.glfwSetFramebufferSizeCallback;
pub const setKeyCallback = c.glfwSetKeyCallback;
pub const setMouseButtonCallback = c.glfwSetMouseButtonCallback;
pub const setScrollCallback = c.glfwSetScrollCallback;
pub const setCharCallback = c.glfwSetCharCallback;
pub const getWindowUserPointer = c.glfwGetWindowUserPointer;
pub const waitEvents = c.glfwWaitEvents;
