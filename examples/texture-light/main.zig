// in this example:
//   - comptime generated image data for texture
//   - Blinn-Phong lightning
//   - several pipelines
//
// quit with escape, q or space
// move camera with arrows or wasd

const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const glfw = @import("glfw");
const zm = @import("zmath");

const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;

const App = mach.App(*FrameParams, .{});

var global_params: *FrameParams = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    const ctx = try allocator.create(FrameParams);
    global_params = ctx; // TODO ugly hack to use ctx from glfw callbacks
    var app = try App.init(allocator, ctx, .{});

    app.window.setKeyCallback(keyCallback);
    // todo
    // app.window.setKeyCallback(struct {
    //     fn callback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    //         _ = scancode;
    //         _ = mods;
    //         if (action == .press) {
    //             switch (key) {
    //                 .space => window.setShouldClose(true),
    //                 else => {},
    //             }
    //         }
    //     }
    // }.callback);
    try app.window.setSizeLimits(.{ .width = 20, .height = 20 }, .{ .width = null, .height = null });

    const eye = vec3(5.0, 7.0, 5.0);
    const target = vec3(0.0, 0.0, 0.0);

    const size = try app.window.getFramebufferSize();
    const aspect_ratio = @intToFloat(f32, size.width) / @intToFloat(f32, size.height);

    ctx.* = FrameParams{
        .queue = app.device.getQueue(),
        .cube = Cube.init(app),
        .light = Light.init(app),
        .depth = Texture.depth(app.device, size.width, size.height),
        .depth_size = size,
        .camera = Camera.init(app.device, eye, target, vec3(0.0, 1.0, 0.0), aspect_ratio, 45.0, 0.1, 100.0),
    };

    try app.run(.{ .frame = frame });
}

const FrameParams = struct {
    queue: gpu.Queue,
    cube: Cube,
    camera: Camera,
    light: Light,
    depth: Texture,
    depth_size: glfw.Window.Size,
    keys: u8 = 0,

    const up:    u8 = 0b0001;
    const down:  u8 = 0b0010;
    const left:  u8 = 0b0100;
    const right: u8 = 0b1000;
};

fn frame(app: *App, params: *FrameParams) !void {
    // If window is resized, recreate depth buffer otherwise we cannot use it.
    const size = app.window.getFramebufferSize() catch unreachable; // TODO: return type inference can't handle this
    if (size.width != params.depth_size.width or size.height != params.depth_size.height) {
        params.depth = Texture.depth(app.device, size.width, size.height);
        params.depth_size = size;
    }

    // move camera
    const speed = zm.f32x4s(0.2);
    const fwd = zm.normalize3(params.camera.target - params.camera.eye);
    const right = zm.normalize3(zm.cross3(fwd, params.camera.up));

    if (params.keys & FrameParams.up != 0)
        params.camera.eye += fwd * speed;

    if (params.keys & FrameParams.down != 0)
        params.camera.eye -= fwd * speed;

    if (params.keys & FrameParams.right != 0)
        params.camera.eye += right * speed;

    if (params.keys & FrameParams.left != 0)
        params.camera.eye -= right * speed;

    params.camera.update(params.queue);

    // move light
    params.light.update(params.queue);

    const back_buffer_view = app.swap_chain.?.getCurrentTextureView();
    defer back_buffer_view.release();

    const encoder = app.device.createCommandEncoder(null);
    defer encoder.release();

    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = gpu.Color{.r=0.0, .g=0.0, .b=0.4, .a=1.0},
        .load_op = .clear,
        .store_op = .store,
    };

    const render_pass_descriptor = gpu.RenderPassEncoder.Descriptor{
        .color_attachments = &.{
            color_attachment
        },
        .depth_stencil_attachment = &.{
            .view = params.depth.view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .stencil_load_op = .none,
            .stencil_store_op = .none,
            .depth_clear_value = 1.0,
        },
    };

    const pass = encoder.beginRenderPass(&render_pass_descriptor);
    defer pass.release();

    // brick cubes
    pass.setPipeline(params.cube.pipeline);
    pass.setBindGroup(0, params.camera.bind_group, &.{});
    pass.setBindGroup(1, params.cube.texture.bind_group, &.{});
    pass.setBindGroup(2, params.light.bind_group, &.{});
    pass.setVertexBuffer(0, params.cube.mesh.buffer, 0, params.cube.mesh.size);
    pass.setVertexBuffer(1, params.cube.instance.buffer, 0, params.cube.instance.size);
    pass.draw(4, params.cube.instance.len,  0, 0);
    pass.draw(4, params.cube.instance.len,  4, 0);
    pass.draw(4, params.cube.instance.len,  8, 0);
    pass.draw(4, params.cube.instance.len, 12, 0);
    pass.draw(4, params.cube.instance.len, 16, 0);
    pass.draw(4, params.cube.instance.len, 20, 0);

    // light source
    pass.setPipeline(params.light.pipeline);
    pass.setBindGroup(0, params.camera.bind_group, &.{});
    pass.setBindGroup(1, params.light.bind_group, &.{});
    pass.setVertexBuffer(0, params.cube.mesh.buffer, 0, params.cube.mesh.size);
    pass.draw(4, 1,  0, 0);
    pass.draw(4, 1,  4, 0);
    pass.draw(4, 1,  8, 0);
    pass.draw(4, 1, 12, 0);
    pass.draw(4, 1, 16, 0);
    pass.draw(4, 1, 20, 0);

    pass.end();

    var command = encoder.finish(null);
    defer command.release();

    params.queue.submit(&.{command});
    app.swap_chain.?.present();
}

const Camera = struct {
    const Self = @This();
    
    eye: Vec,
    target: Vec,
    up: Vec,
    aspect: f32,
    fovy: f32,
    near: f32,
    far: f32,
    bind_group: gpu.BindGroup,
    buffer: Buffer,

    const Uniform = struct {
        pos: Vec,
        mat: Mat,
    };

    fn init(device: gpu.Device, eye: Vec, target: Vec, up: Vec, aspect: f32, fovy: f32, near: f32, far: f32) Self {
        var self: Self = .{
            .eye = eye,
            .target = target,
            .up = up,
            .aspect = aspect,
            .near = near,
            .far = far,
            .fovy = fovy,
            .buffer = undefined,
            .bind_group = undefined,
        };

        const view = self.buildViewProjMatrix();

        const uniform = .{
            .pos = self.eye,
            .mat = view,
        };

        const buffer = .{
            .buffer = initBuffer(device, .{.uniform=true}, &@bitCast([20]f32, uniform)),
            .size = @sizeOf(@TypeOf(uniform)),
        };

        const bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor{
            .layout = Self.bindGroupLayout(device),
            .entries = &[_]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.buffer(0, buffer.buffer, 0, buffer.size),
            },
        });

        self.buffer = buffer;
        self.bind_group = bind_group;

        return self;
    }

    fn update(self: *Self, queue: gpu.Queue) void {
        const mat = self.buildViewProjMatrix();
        const uniform = .{
            .pos = self.eye,
            .mat = mat,
        };

        queue.writeBuffer(self.buffer.buffer, 0, Uniform, &.{uniform});
    }

    inline fn buildViewProjMatrix(s: *const Camera) Mat {
        const view = zm.lookAtRh(s.eye, s.target, s.up);
        const proj = zm.perspectiveFovRh(s.fovy, s.aspect, s.near, s.far);
        return zm.mul(view, proj);
    }

    inline fn bindGroupLayout(device: gpu.Device) gpu.BindGroupLayout {
        const visibility = .{ .vertex = true, .fragment = true };
        return device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor{
            .entries = &[_]gpu.BindGroupLayout.Entry{
                gpu.BindGroupLayout.Entry.buffer(0, visibility, .uniform, false, 0),
            },
        });
    }
};

const Buffer = struct {
    buffer: gpu.Buffer,
    size: usize,
    len: u32 = 0,
};

const Cube = struct {
    const Self = @This();

    pipeline: gpu.RenderPipeline,
    mesh: Buffer,
    instance: Buffer,
    texture: Texture,

    const IPR = 10; // instances per row
    const SPACING = 2; // spacing between cubes
    const DISPLACEMENT = vec3u(IPR * SPACING / 2, 0, IPR * SPACING / 2);

    fn init(app: App) Self {
        const device = app.device;

        const texture = Brick.texture(device);

        // instance buffer
        var ibuf: [IPR*IPR*16]f32 = undefined;

        var z: usize = 0;
        while (z < IPR) : (z += 1) {
            var x: usize = 0;
            while (x < IPR) : (x += 1) {
                const pos = vec3u(x * SPACING, 0, z * SPACING) - DISPLACEMENT;
                const rot = blk: {
                    if (pos[0] == 0 and pos[2] == 0) {
                        break :blk zm.quatFromAxisAngle(vec3u(0, 0, 1), 0.0);
                    } else {
                        break :blk zm.quatFromAxisAngle(zm.normalize3(pos), 45.0);
                    }
                };
                const index = z * IPR + x;
                const inst = Instance{
                    .position = pos,
                    .rotation = rot,
                };
                zm.storeMat(ibuf[index * 16 ..], inst.toMat());
            }
        }

        const instance = Buffer {
            .buffer = initBuffer(device, .{.vertex=true}, &ibuf),
            .len = IPR * IPR,
            .size = @sizeOf(@TypeOf(ibuf)),
        };

        return Self {
            .mesh = mesh(device),
            .texture = texture,
            .instance = instance,
            .pipeline = pipeline(app),
        };
    }

    fn pipeline(app: App) gpu.RenderPipeline {
        const device = app.device;

        const layout_descriptor = gpu.PipelineLayout.Descriptor{
            .bind_group_layouts = &.{
                Camera.bindGroupLayout(device),
                Texture.bindGroupLayout(device),
                Light.bindGroupLayout(device),
            },
        };

        const layout = device.createPipelineLayout(&layout_descriptor);
        defer layout.release();

        const shader = device.createShaderModule(&.{
            .code = .{ .wgsl = @embedFile("cube.wgsl") },
        });
        defer shader.release();

        const blend = gpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .zero,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .zero,
            },
        };

        const color_target = gpu.ColorTargetState{
            .format = app.swap_chain_format,
            .write_mask = gpu.ColorWriteMask.all,
            .blend = &blend,
        };

        const fragment = gpu.FragmentState{
            .module = shader,
            .entry_point = "fs_main",
            .targets = &.{color_target},
            .constants = null,
        };

        const descriptor = gpu.RenderPipeline.Descriptor{
            .layout = layout,
            .fragment = &fragment,
            .vertex = .{
                .module = shader,
                .entry_point = "vs_main",
                .buffers = &.{
                    Self.vertexBufferLayout(),
                    Self.instanceLayout(), 
                },
            },
            .depth_stencil = &.{
                .format = Texture.DEPTH_FORMAT,
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
            .primitive = .{
                .front_face = .ccw,
                .cull_mode = .back,
                // .cull_mode = .none,
                .topology = .triangle_strip,
                .strip_index_format = .none,
            },
        };

        return device.createRenderPipeline(&descriptor); 
    }

    fn mesh(device: gpu.Device) Buffer {
        // generated texture has aspect ratio of 1:2
        // `h` reflects that ratio
        // `v` sets how many times texture repeats across surface
        const v = 2;
        const h = v * 2;
        const buf = asFloats(.{
            // z+ face
            0, 0, 1,  0,  0,  1,  0, h,
            1, 0, 1,  0,  0,  1,  v, h,
            0, 1, 1,  0,  0,  1,  0, 0,
            1, 1, 1,  0,  0,  1,  v, 0,
            // z- face
            1, 0, 0,  0,  0, -1,  0, h,
            0, 0, 0,  0,  0, -1,  v, h,
            1, 1, 0,  0,  0, -1,  0, 0,
            0, 1, 0,  0,  0, -1,  v, 0,
            // x+ face
            1, 0, 1,  1,  0,  0,  0, h,
            1, 0, 0,  1,  0,  0,  v, h,
            1, 1, 1,  1,  0,  0,  0, 0,
            1, 1, 0,  1,  0,  0,  v, 0,
            // x- face
            0, 0, 0, -1,  0,  0,  0, h,
            0, 0, 1, -1,  0,  0,  v, h,
            0, 1, 0, -1,  0,  0,  0, 0,
            0, 1, 1, -1,  0,  0,  v, 0,
            // y+ face
            1, 1, 0,  0,  1,  0,  0, h,
            0, 1, 0,  0,  1,  0,  v, h,
            1, 1, 1,  0,  1,  0,  0, 0,
            0, 1, 1,  0,  1,  0,  v, 0,
            // y- face
            0, 0, 0,  0, -1,  0,  0, h,
            1, 0, 0,  0, -1,  0,  v, h,
            0, 0, 1,  0, -1,  0,  0, 0,
            1, 0, 1,  0, -1,  0,  v, 0,
        });

        return Buffer {
            .buffer = initBuffer(device, .{.vertex=true}, &buf),
            .size = @sizeOf(@TypeOf(buf)),
        };
    }

    fn vertexBufferLayout() gpu.VertexBufferLayout {
        const attributes = [_]gpu.VertexAttribute{
            .{
                .format = .float32x3,
                .offset = 0,
                .shader_location = 0,
            },
            .{
                .format = .float32x3,
                .offset = @sizeOf([3]f32),
                .shader_location = 1,
            },
            .{
                .format = .float32x2,
                .offset = @sizeOf([6]f32),
                .shader_location = 2,
            },
        };
        return gpu.VertexBufferLayout{
            .array_stride = @sizeOf([8]f32),
            .step_mode = .vertex,
            .attribute_count = attributes.len,
            .attributes = &attributes,
        };
    }

    fn instanceLayout() gpu.VertexBufferLayout {
         const attributes = [_]gpu.VertexAttribute{
            .{
                .format = .float32x4,
                .offset = 0,
                .shader_location = 3,
            },
            .{
                .format = .float32x4,
                .offset = @sizeOf([4]f32),
                .shader_location = 4,
            },
            .{
                .format = .float32x4,
                .offset = @sizeOf([8]f32),
                .shader_location = 5,
            },
            .{
                .format = .float32x4,
                .offset = @sizeOf([12]f32),
                .shader_location = 6,
            },
        };

        return gpu.VertexBufferLayout{
            .array_stride = @sizeOf([16]f32),
            .step_mode = .instance,
            .attribute_count = attributes.len,
            .attributes = &attributes,
        };
   }
};

fn asFloats(comptime arr: anytype) [arr.len]f32 {
    comptime var len = arr.len;
    comptime var out: [len]f32 = undefined;
    comptime var i = 0;
    inline while (i < len) : (i += 1) {
        out[i] = @intToFloat(f32, arr[i]);
    }
    return out;
}

const Brick = struct {
    const W = 12;
    const H = 6;

    fn texture(device: gpu.Device) Texture {
        const slice: []const u8 = &data();
        return Texture.fromData(device, W, H, slice);
    }

    fn data() [W*H*4]u8 {
        comptime var out: [W*H*4]u8 = undefined;

        // fill all the texture with brick color
        comptime var i = 0;
        inline while (i < H) : (i += 1) {
            comptime var j = 0;
            inline while (j < W * 4) : (j += 4) {
                out[i * W * 4 + j + 0] = 210;
                out[i * W * 4 + j + 1] = 30;
                out[i * W * 4 + j + 2] = 30;
                out[i * W * 4 + j + 3] = 0;
            }
        }

        const f = 10;

        // fill the cement lines
        inline for ([_]comptime_int{ 0, 1 }) |k| {
            inline for ([_]comptime_int{ 5 * 4, 11 * 4 }) |m| {
                out[k * W * 4 + m + 0] = f;
                out[k * W * 4 + m + 1] = f;
                out[k * W * 4 + m + 2] = f;
                out[k * W * 4 + m + 3] = 0;
            }
        }

        inline for ([_]comptime_int{ 3, 4 }) |k| {
            inline for ([_]comptime_int{ 2 * 4, 8 * 4 }) |m| {
                out[k * W * 4 + m + 0] = f;
                out[k * W * 4 + m + 1] = f;
                out[k * W * 4 + m + 2] = f;
                out[k * W * 4 + m + 3] = 0;
            }
        }

        inline for ([_]comptime_int{ 2, 5 }) |k| {
            comptime var m = 0;
            inline while (m < W * 4) : (m += 4) {
                out[k * W * 4 + m + 0] = f;
                out[k * W * 4 + m + 1] = f;
                out[k * W * 4 + m + 2] = f;
                out[k * W * 4 + m + 3] = 0;
            }
        }

        return out;
    }
};

// don't confuse with gpu.Texture
const Texture = struct {
    const Self = @This();

    texture: gpu.Texture,
    view: gpu.TextureView,
    sampler: gpu.Sampler,
    bind_group: gpu.BindGroup,

    const DEPTH_FORMAT = .depth32_float;
    const FORMAT = .rgba8_unorm;

    fn release(self: *Self) void {
        self.texture.release();
        self.view.release();
        self.sampler.release();
    }

    fn fromData(device: gpu.Device, width: u32, height: u32, data: anytype) Self {
        const extent = gpu.Extent3D {
            .width = width,
            .height = height,
        };

        const texture = device.createTexture(&gpu.Texture.Descriptor{
            .size = extent,
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .dimension_2d,
            .format = FORMAT,
            .usage = .{ .copy_dst = true, .texture_binding = true },
        });

        const view = texture.createView(&gpu.TextureView.Descriptor{
            .aspect = .all,
            .format = FORMAT,
            .dimension = .dimension_2d,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .mip_level_count = 1,
            .base_mip_level = 0,
        });

        const sampler = device.createSampler(&gpu.Sampler.Descriptor{
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .compare = .none,
            .lod_min_clamp = 0.0,
            .lod_max_clamp = std.math.f32_max,
            .max_anisotropy = 1, // 1,2,4,8,16
        });

        device.getQueue().writeTexture(
            &gpu.ImageCopyTexture{ .texture = texture, },
            data,
            &gpu.Texture.DataLayout {
                .bytes_per_row = 4 * width,
                .rows_per_image = height,
            },
            &extent,
        );

        const bind_group_layout = Self.bindGroupLayout(device);
        const bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor{
            .layout = bind_group_layout,
            .entries = &[_]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.textureView(0, view),
                gpu.BindGroup.Entry.sampler(1, sampler),
            },
        });

        return Self {
            .view = view,
            .texture = texture,
            .sampler = sampler,
            .bind_group = bind_group,
        };
    }

    fn depth(device: gpu.Device, width: u32, height: u32) Self {
        const extent = gpu.Extent3D {
            .width = width,
            .height = height,
        };

        const texture = device.createTexture(&gpu.Texture.Descriptor{
            .size = extent,
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .dimension_2d,
            .format = DEPTH_FORMAT,
            .usage = .{
                .render_attachment = true,
                .texture_binding = true,
            },
        });

        const view = texture.createView(&gpu.TextureView.Descriptor{
            .aspect = .all,
            .format = .none,
            .dimension = .dimension_2d,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .mip_level_count = 1,
            .base_mip_level = 0,
        });

        const sampler = device.createSampler(&gpu.Sampler.Descriptor{
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .compare = .less_equal,
            .lod_min_clamp = 0.0,
            .lod_max_clamp = std.math.f32_max,
            .max_anisotropy = 1,
        });

        return Self {
            .texture = texture,
            .view    = view,
            .sampler = sampler,
            .bind_group = undefined,  // not used
        };
    }

    inline fn bindGroupLayout(device: gpu.Device) gpu.BindGroupLayout {
        const visibility = .{ .fragment = true };
        const Entry = gpu.BindGroupLayout.Entry;
        return device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor{
            .entries = &[_]Entry{
                Entry.texture(0, visibility, .float, .dimension_2d, false),
                Entry.sampler(1, visibility, .filtering),
            },
        });
    }
};

const Light = struct {
    const Self = @This();
    
    uniform: Uniform,
    buffer: Buffer,
    bind_group: gpu.BindGroup,
    pipeline: gpu.RenderPipeline,

    const Uniform = struct {
        position: Vec,
        color: Vec,
    };

    fn init(app: App) Self {
        const device = app.device;
        const uniform = .{
            .color = vec3u(1, 1, 1),
            .position = vec3u(3, 7, 2),
        };

        const buffer = .{
            .buffer = initBuffer(device, .{.uniform = true}, &@bitCast([8]f32, uniform)),
            .size = @sizeOf(@TypeOf(uniform)),
        };

        const bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor{
            .layout = Self.bindGroupLayout(device),
            .entries = &[_]gpu.BindGroup.Entry {
                gpu.BindGroup.Entry.buffer(0, buffer.buffer, 0, buffer.size),
            },
        });

        return Self {
            .buffer = buffer,
            .uniform = uniform,
            .bind_group = bind_group,
            .pipeline = Self.pipeline(app),
        };
    }

    fn update(self: *Self, queue: gpu.Queue) void {
        const old = self.uniform;
        const new = Light.Uniform {
            .position = zm.qmul(zm.quatFromAxisAngle(vec3u(0, 1, 0), 0.05), old.position),
            .color = old.color,
        };
        queue.writeBuffer(self.buffer.buffer, 0, Light.Uniform, &.{new});
        self.uniform = new;
    }

    inline fn bindGroupLayout(device: gpu.Device) gpu.BindGroupLayout {
        const visibility = .{ .vertex = true, .fragment = true };
        const Entry = gpu.BindGroupLayout.Entry;
        return device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor{
            .entries = &[_]Entry{
                Entry.buffer(0, visibility, .uniform, false, 0),
            },
        });
    }

    fn pipeline(app: App) gpu.RenderPipeline {
        const device = app.device;

        const layout_descriptor = gpu.PipelineLayout.Descriptor{
            .bind_group_layouts = &.{
                Camera.bindGroupLayout(device),
                Light.bindGroupLayout(device),
            },
        };

        const layout = device.createPipelineLayout(&layout_descriptor);
        defer layout.release();

        const shader = device.createShaderModule(&.{
            .code = .{ .wgsl = @embedFile("light.wgsl") },
        });
        defer shader.release();

        const blend = gpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .zero,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .zero,
            },
        };

        const color_target = gpu.ColorTargetState{
            .format = app.swap_chain_format,
            .write_mask = gpu.ColorWriteMask.all,
            .blend = &blend,
        };

        const fragment = gpu.FragmentState{
            .module = shader,
            .entry_point = "fs_main",
            .targets = &.{color_target},
            .constants = null,
        };

        const descriptor = gpu.RenderPipeline.Descriptor{
            .layout = layout,
            .fragment = &fragment,
            .vertex = .{
                .module = shader,
                .entry_point = "vs_main",
                .buffers = &.{
                    Cube.vertexBufferLayout(),
                },
            },
            .depth_stencil = &.{
                .format = Texture.DEPTH_FORMAT,
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
            .primitive = .{
                .front_face = .ccw,
                .cull_mode = .back,
                // .cull_mode = .none,
                .topology = .triangle_strip,
                .strip_index_format = .none,
            },
        };

        return device.createRenderPipeline(&descriptor); 
    }
};

inline fn initBuffer(device: gpu.Device, usage: gpu.BufferUsage, data: anytype) gpu.Buffer {
    std.debug.assert(@typeInfo(@TypeOf(data)) == .Pointer);
    const T = std.meta.Elem(@TypeOf(data));

    var u = usage; 
    u.copy_dst = true;
    const buffer = device.createBuffer(&.{
        .size = @sizeOf(T) * data.len,
        .usage = u,
        .mapped_at_creation = true,
    });

    var mapped = buffer.getMappedRange(T, 0, data.len);
    std.mem.copy(T, mapped, data);
    buffer.unmap();
    return buffer;
}

fn vec3i(x: isize, y: isize, z: isize) Vec {
    return zm.f32x4(@intToFloat(f32, x), @intToFloat(f32, y), @intToFloat(f32, z), 0.0);
}

fn vec3u(x: usize, y: usize, z: usize) Vec {
    return zm.f32x4(@intToFloat(f32, x), @intToFloat(f32, y), @intToFloat(f32, z), 0.0);
}

fn vec3(x: f32, y: f32, z: f32) Vec {
    return zm.f32x4(x, y, z, 0.0);
}

fn vec4(x: f32, y: f32, z: f32, w: f32) Vec {
    return zm.f32x4(x, y, z, w);
}

// todo indside Cube
const Instance = struct {
    const Self = @This();
    
    position: Vec,
    rotation: Quat,

    fn toMat(self: *const Self) Mat {
        return zm.mul(zm.quatToMat(self.rotation), zm.translationV(self.position));
    }
};

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;
    _ = mods;

    if (action == .press) {
        switch (key) {
            .q, .escape, .space => window.setShouldClose(true),
            .w, .up    => { global_params.keys |= FrameParams.up; },
            .s, .down  => { global_params.keys |= FrameParams.down; },
            .a, .left  => { global_params.keys |= FrameParams.left; },
            .d, .right => { global_params.keys |= FrameParams.right; },
            else => {},
        }
    } else if (action == .release) {
        switch (key) {
            .w, .up    => { global_params.keys &= ~FrameParams.up; },
            .s, .down  => { global_params.keys &= ~FrameParams.down; },
            .a, .left  => { global_params.keys &= ~FrameParams.left; },
            .d, .right => { global_params.keys &= ~FrameParams.right; },
            else => {},
        }
    }
}
