const c = @import("c.zig").c;

pub const client_api = c.GLFW_CLIENT_API;
pub const no_api = c.GLFW_NO_API;
pub const resizable = c.GLFW_RESIZABLE;
pub const @"false" = c.GLFW_FALSE;
pub const @"true" = c.GLFW_TRUE;

pub const Window = c.GLFWwindow;

pub const init = c.glfwInit;
pub const windowHint = c.glfwWindowHint;
pub const createWindow = c.glfwCreateWindow;
pub const windowShouldClose = c.glfwWindowShouldClose;
pub const pollEvents = c.glfwPollEvents;
pub const destroyWindow = c.glfwDestroyWindow;
pub const terminate = c.glfwTerminate;
pub const getRequiresInstanceExtensions = c.glfwGetRequiredInstanceExtensions;
pub const createWindowSurface = c.glfwCreateWindowSurface;
pub const getFramebufferSize = c.glfwGetFramebufferSize;
pub const setWindowUserPointer = c.glfwSetWindowUserPointer;
pub const setFramebufferSizeCallback = c.glfwSetFramebufferSizeCallback;
pub const getWindowUserPointer = c.glfwGetWindowUserPointer;
pub const waitEvents = c.glfwWaitEvents;

