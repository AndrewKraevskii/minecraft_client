const std = @import("std");

const log = std.log.scoped(.minecraft_network);

const PacketId = enum(u8) {
    // zig fmt: off
    @"Keep Alive"                    = 0x00,
    @"Login Request"                 = 0x01,
    Handshake                        = 0x02,
    @"Chat Message"                  = 0x03,
    @"Time Update"                   = 0x04,
    @"Entity Equipment"              = 0x05,
    @"Spawn Position"                = 0x06,
    @"Use Entity"                    = 0x07,
    @"Update Health"                 = 0x08,
    Respawn                          = 0x09,
    Player                           = 0x0A,
    @"Player Position"               = 0x0B,
    @"Player Look"                   = 0x0C,
    @"Player Position and Look"      = 0x0D,
    @"Player Digging"                = 0x0E,
    @"Player Block Placement"        = 0x0F,
    @"Held Item Change"              = 0x10,
    @"Use Bed"                       = 0x11,
    Animation                        = 0x12,
    @"Entity Action"                 = 0x13,
    @"Spawn Named Entity"            = 0x14,
    @"Collect Item"                  = 0x16,
    @"Spawn Object/Vehicle"          = 0x17,
    @"Spawn Mob"                     = 0x18,
    @"Spawn Painting"                = 0x19,
    @"Spawn Experience Orb"          = 0x1A,
    @"Entity Velocity"               = 0x1C,
    @"Destroy Entity"                = 0x1D,
    Entity                           = 0x1E,
    @"Entity Relative Move"          = 0x1F,
    @"Entity Look"                   = 0x20,
    @"Entity Look and Relative Move" = 0x21,
    @"Entity Teleport"               = 0x22,
    @"Entity Head Look"              = 0x23,
    @"Entity Status"                 = 0x26,
    @"Attach Entity"                 = 0x27,
    @"Entity Metadata"               = 0x28,
    @"Entity Effect"                 = 0x29,
    @"Remove Entity Effect"          = 0x2A,
    @"Set Experience"                = 0x2B,
    @"Chunk Data"                    = 0x33,
    @"Multi Block Change"            = 0x34,
    @"Block Change"                  = 0x35,
    @"Block Action"                  = 0x36,
    @"Block Break Animation"         = 0x37,
    @"Map Chunk Bulk"                = 0x38,
    Explosion                        = 0x3C,
    @"Sound Or Particle Effect"      = 0x3D,
    @"Named Sound Effect"            = 0x3E,
    Particle                         = 0x3F,
    @"Change Game State"             = 0x46,
    @"Spawn Global Entity"           = 0x47,
    @"Open Window"                   = 0x64,
    @"Close Window"                  = 0x65,
    @"Click Window"                  = 0x66,
    @"Set Slot"                      = 0x67,
    @"Set Window Items"              = 0x68,
    @"Update Window Property"        = 0x69,
    @"Confirm Transaction"           = 0x6A,
    @"Creative Inventory Action"     = 0x6B,
    @"Enchant Item"                  = 0x6C,
    @"Update Sign"                   = 0x82,
    @"Item Data"                     = 0x83,
    @"Update Tile Entity"            = 0x84,
    @"Increment Statistic"           = 0xC8,
    @"Player List Item"              = 0xC9,
    @"Player Abilities"              = 0xCA,
    @"Tab-complete"                  = 0xCB,
    @"Client Settings"               = 0xCC,
    @"Client Statuses"               = 0xCD,
    @"Scoreboard Objective"          = 0xCE,
    @"Update Score"                  = 0xCF,
    @"Display Scoreboard"            = 0xD0,
    Teams                            = 0xD1,
    @"Plugin Message"                = 0xFA,
    @"Encryption Key Response"       = 0xFC,
    @"Encryption Key Request"        = 0xFD,
    @"Server List Ping"              = 0xFE,
    @"Disconnect/Kick"               = 0xFF,
    // zig fmt: on
};

const String = struct {
    utf8: []const u8,

    pub fn fromUtf8(utf8: []const u8) String {
        return .{
            .utf8 = utf8,
        };
    }
};

const ObjectData = extern struct { value: i32 };

const EntityMetadata =
    [1 << 5]union(enum) {
        byte: u8,
        short: u16,
        int: u32,
        float: f32,
        string: String,
        slot: ?Slot,
        pos: struct { x: i32, y: i32, z: i32 },
        empty,
    };

const Slot = struct {
    id: u16,
    count: u8,
    damage: u16,

    pub fn parse(reader: anytype) !?Slot {
        const id = try reader.readInt(i16, .big);
        if (id == -1) {
            return null;
        }
        const count = try reader.readInt(u8, .big);
        const damage = try reader.readInt(u16, .big);
        const nbt_len = try reader.readInt(i16, .big);
        if (nbt_len != -1) {
            try reader.skipBytes(@intCast(nbt_len), .{});
        }
        return .{
            .id = @intCast(id),
            .count = count,
            .damage = damage,
        };
    }
};

pub const Packet = union(PacketId) {
    @"Keep Alive": struct {
        id: i32,
    },
    @"Login Request": struct {
        player_id: i32,
        _level_type: String,
        // TODO: Bit 3 (0x8) is the hardcore flag
        game_mode: enum(u8) {
            survival = 0,
            creative = 1,
            adventure = 2,
        },
        dimension: enum(i8) {
            nether = -1,
            overworld = 0,
            end = 1,
        },
        difficulty: enum(u8) {
            peaceful = 0,
            easy = 1,
            normal = 2,
            hard = 3,
        },
        _padding: u8,
        max_players: u8,
    },
    Handshake: struct {
        protocol_version: u8,
        username: String,
        server_host: String,
        server_port: i32,
    },
    @"Chat Message": struct {
        message: String,
    },
    @"Time Update": struct {
        age_of_the_world: i64,
        time_of_day: i64,
    },
    @"Entity Equipment": struct {
        entity_id: i32,
        slot: i16,
        item: ?Slot,
    },
    @"Spawn Position": struct {
        x: i32,
        y: i32,
        z: i32,
    },
    @"Use Entity": struct {
        user: i32,
        target: i32,
        left_mouse_button: bool,
    },
    @"Update Health": struct {
        health: i16,
        food: i16,
        food_sturation: f32,
    },
    Respawn: struct {
        dimension: i32,
        difficulty: u8,
        game_mode: u8,
        world_heigth: i16,
        level_type: String,
    },
    Player: struct {
        on_ground: bool,
    },
    @"Player Position": struct {
        x: f64,
        y: f64,
        stance: f64,
        z: f64,
        on_ground: bool,
    },
    @"Player Look": struct {
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    @"Player Position and Look": struct {
        x: f64,
        y: f64,
        stance: f64,
        z: f64,
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    @"Player Digging": struct {
        status: enum(u8) {
            @"Started digging" = 0,
            @"Cancelled digging" = 1,
            @"Finished digging" = 2,
            @"Drop item stack" = 3,
            @"Drop item" = 4,
            @"Shoot arrow / finish eating" = 5,
        },
        x: i32,
        y: u8,
        z: i32,
        face: enum(u8) {
            @"-y" = 0,
            @"+y" = 1,
            @"-z" = 2,
            @"+z" = 3,
            @"-x" = 4,
            @"+x" = 5,
        },
    },
    @"Player Block Placement": struct {
        x: i32,
        y: u8,
        z: i32,
        direction: i8,
        held_item: ?Slot,
        cursor_pos_x: u8,
        cursor_pos_y: u8,
        cursor_pos_z: u8,
    },
    @"Held Item Change": struct {
        slot_id: u16,
    },
    @"Use Bed": struct {
        entity_id: i32,
        _unknown: u8,
        x: i32,
        y: i8,
        z: i32,
    },
    Animation: struct {
        entity_id: i32,
        animation: enum(u8) {
            @"No animation" = 0,
            @"Swing arm" = 1,
            @"Damage animation" = 2,
            @"Leave bed" = 3,
            @"Eat food" = 5,
            @"(unknown)" = 102,
            Crouch = 104,
            Uncrouch = 105,
        },
    },
    @"Entity Action": struct {
        entity_id: i32,
        animation: enum(u8) {
            Crouch = 1,
            Uncrouch = 2,
            @"Leave bed" = 3,
            @"Start sprinting" = 4,
            @"Stop sprinting" = 5,
        },
    },
    @"Spawn Named Entity": struct {
        entity_id: i32,
        player_name: String,
        x: i32,
        y: i32,
        z: i32,
        yaw: i8,
        pitch: i8,
        current_item: i16,
        metadata: EntityMetadata,
    },
    @"Collect Item": struct {
        collected_eid: i32,
        collector_eid: i32,
    },
    @"Spawn Object/Vehicle": struct {
        entity_id: i32,
        type: u8,
        x: i32,
        y: i32,
        z: i32,
        pitch: i8,
        yaw: i8,
        object_data: i32,
        speed_x: i16,
        speed_y: i16,
        speed_z: i16,
    },
    @"Spawn Mob": struct {
        eid: i32,
        type: u8,
        x: i32,
        y: i32,
        z: i32,
        pitch: i8,
        head_pitch: i8,
        yaw: i8,
        velocity_x: i16,
        velocity_y: i16,
        velocity_z: i16,
        metadata: EntityMetadata,
    },
    @"Spawn Painting": struct {
        entity_id: i32,
        title: String,
        x: i32,
        y: i32,
        z: i32,
        direction: i32,
    },
    @"Spawn Experience Orb": struct {
        entity_id: i32,
        x: i32,
        y: i32,
        z: i32,
        count: i16,
    },
    @"Entity Velocity": struct {
        entity_id: i32,
        velocity_x: i16,
        velocity_y: i16,
        velocity_z: i16,
    },
    @"Destroy Entity": struct {
        entitys_len: u8,
        entitys: []const extern struct { id: i32 },
    },
    /// Entity did nothing
    Entity: struct {
        entity_id: i32,
    },
    @"Entity Relative Move": struct {
        entity_id: i32,
        dx: i8,
        dy: i8,
        dz: i8,
    },
    @"Entity Look": struct {
        entity_id: i32,
        yaw: i8,
        pitch: i8,
    },
    @"Entity Look and Relative Move": struct {
        entity_id: i32,
        dx: i8,
        dy: i8,
        dz: i8,
        yaw: i8,
        pitch: i8,
    },
    @"Entity Teleport": struct {
        entity_id: i32,
        x: i32,
        y: i32,
        z: i32,
        yaw: i8,
        pitch: i8,
    },
    @"Entity Head Look": struct {
        entity_id: i32,
        head_yaw: u8,
    },
    @"Entity Status": struct {
        entity_id: i32,
        status: enum(u8) {
            @"Entity hurt" = 2,
            @"Entity dead" = 3,
            @"Wolf taming" = 6,
            @"Wolf tamed" = 7,
            @"Wolf shaking water off itself" = 8,
            @"(of self) Eating accepted by server" = 9,
            @"Sheep eating grass" = 10,
            @"Iron Golem handing over a rose" = 11,
            @"Spawn \"heart\" particles near a villager" = 12,
            @"Spawn particles indicating that a villager is angry and seeking revenge" = 13,
            @"Spawn happy particles near a villager" = 14,
            @"Spawn a \"magic\" particle near the Witch" = 15,
            @"Zombie converting into a villager by shaking violently" = 16,
            @"A firework exploding" = 17,
        },
    },
    @"Attach Entity": struct {
        entity_id: i32,
        vehicle_id: i32,
    },
    @"Entity Metadata": struct {
        entity_id: i32,
        metadata: EntityMetadata,
    },
    @"Entity Effect": struct {
        entity_id: i32,
        effect_id: u8,
        amplifier: u8,
        duration: i16,
    },
    @"Remove Entity Effect": struct {
        entity_id: i32,
        effect_id: i8,
    },
    @"Set Experience": struct {
        experience_bar: f32,
        level: i16,
        total_experience: i16,
    },
    @"Chunk Data": struct {
        x: i32,
        y: i32,
        ground_up_continuous: bool,
        primary_bit_map: u16,
        add_bit_map: u16,
        compressed_data_len: i32,
        compressed_data: []const u8,
    },
    @"Multi Block Change": struct {
        chunk_x: i32,
        chunk_y: i32,
        data_len: u16,
        data_size: u32,
        data: []const packed struct {
            block_metadata: u4,
            block_id: u12,
            y_coodrinate: u8,
            /// relative to chunk
            z_coodrinate: u4,
            /// relative to chunk
            x_coodrinate: u4,
        },
    },
    @"Block Change": struct {
        x: i32,
        y: i8,
        z: i32,
        block_type: i16,
        block_metadata: i8,
    },
    @"Block Action": struct {
        x: i32,
        y: i16,
        z: i32,
        byte1: u8,
        byte2: u8,
        block_id: i16,
    },
    @"Block Break Animation": struct {
        entity_id: i32,
        x: i32,
        y: i32,
        z: i32,
        destroy_stage: u8,
    },
    @"Map Chunk Bulk": struct {
        chunk_column_len: u16,
        data_len: u32,
        sky_light_sent: bool,
        data: []const u8,
        chunk_column: []const extern struct {
            chunk_x: i32,
            chunk_z: i32,
            primary_bitmap: u16,
            add_bitmap: u16,
        },
    },
    Explosion: struct {
        x: f64,
        y: f64,
        z: f64,
        radius: f32,
        records_len: u32,
        records: []const extern struct {
            x: i8,
            y: i8,
            z: i8,
        },
        player_motion_x: f32,
        player_motion_y: f32,
        player_motion_z: f32,
    },
    @"Sound Or Particle Effect": struct {
        effect_id: i32,
        x: i32,
        y: i8,
        z: i32,
        data: i32,
        disable_relative_volume: bool,
    },
    @"Named Sound Effect": struct {
        sound_name: String,
        x: i32,
        y: i32,
        z: i32,
        volume: f32,
        pitch: u8,
    },
    Particle: struct {
        name: String,
        x: f32,
        y: f32,
        z: f32,
        offset_x: f32,
        offset_y: f32,
        offset_z: f32,
        particle_speed: f32,
        number_of_particles: i32,
    },
    @"Change Game State": struct {
        reason: u8,
        game_mode: enum(u8) {
            survival = 0,
            creative = 1,
        },
    },
    @"Spawn Global Entity": struct {
        entity_id: i32,
        type: u8,
        x: i32,
        y: i32,
        z: i32,
    },
    @"Open Window": struct {
        window_id: u8,
        inventory_type: u8,
        window_title: String,
        number_of_slots: u8,
        use_provided_window_title: bool,
    },
    @"Close Window": struct {
        window_id: u8,
    },
    @"Click Window": struct {
        window_id: u8,
        slot: i16,
        button: u8,
        action_number: i16,
        mode: u8,
        clicked_item: ?Slot,
    },
    @"Set Slot": struct {
        window_id: u8,
        slot_index: u16,
        slot_data: ?Slot,
    },
    @"Set Window Items": struct {
        window_id: u8,
        slot_data_len: u16,
        slot_data: []const ?Slot,
    },
    @"Update Window Property": struct {
        window_id: u8,
        property: i16,
        value: i16,
    },
    @"Confirm Transaction": struct {
        window_id: u8,
        action_number: i16,
        accepted: bool,
    },
    @"Creative Inventory Action": struct {
        slot: i16,
        clicked_item: ?Slot,
    },
    @"Enchant Item": struct {
        window_id: u8,
        enchantment: u8,
    },
    @"Update Sign": struct {
        x: i32,
        y: i16,
        z: i32,
        text1: String,
        text2: String,
        text3: String,
        text4: String,
    },
    @"Item Data": struct {
        item_type: i16,
        item_id: i16,
        text_len: u16,
        /// ascii
        text: []const u8,
    },
    @"Update Tile Entity": struct {
        x: i32,
        y: i16,
        z: i32,
        action: u8,
        data_len: u16,
        data: []const u8,
    },
    @"Increment Statistic": struct {
        statistic_id: i32,
        amount: u8,
    },
    @"Player List Item": struct {
        player_name: String,
        online: bool,
        ping: i16, // ms,
    },
    @"Player Abilities": struct {
        flags: packed struct {
            in_creative: bool,
            is_flying: bool,
            can_fly: bool,
            god_mod: bool,
            _padding: u4,
        },
        flying_speed: u8,
        walking_speed: u8,
    },
    @"Tab-complete": struct {
        text: String,
    },
    @"Client Settings": struct {
        locale: String,
        view_distance: u8,
        chat_flags: u8,
        difficulty: u8,
        show_cape: bool,
    },
    @"Client Statuses": struct {
        payload: enum(u8) {
            innitial_spawn = 0,
            respawn_after_death = 1,
        },
    },
    @"Scoreboard Objective": struct {
        objective_name: String,
        objective_value: String,
        create_remove: enum(u8) {
            create = 0,
            remove = 1,
            update = 2,
        },
    },
    @"Update Score": struct {
        item_name: String,
        create_remove: enum(u8) {
            crate_update = 0,
            remove = 1,
        },
        score_name: String,
        value: i32,
    },
    @"Display Scoreboard": struct {
        position: u8,
        score_name: String,
    },
    Teams: struct {
        team_name: String,
        mode: u8,
        team_display_name: String,
        team_prefix: String,
        team_suffix: String,
        friendly_fire: u8,
        players_len: u16,
        players: []const String,
    },
    @"Plugin Message": struct {
        channel: String,
        data_len: i16,
        data: []const u8,
    },
    @"Encryption Key Response": struct {
        shared_secret_len: u16,
        shared_secret: []const u8,
        verify_token_len: u16,
        verify_token: []const u8,
    },
    @"Encryption Key Request": struct {
        server_id: String,
        public_key_len: u16,
        public_key: []const u8,
        verify_token_len: u16,
        verify_token: []const u8,
    },
    @"Server List Ping": struct {
        /// always 1
        magic: u8 = 1,
    },
    @"Disconnect/Kick": struct {
        reason: String,
    },

    pub fn read(reader: anytype, arena: std.mem.Allocator) !Packet {
        @setEvalBranchQuota(2000);

        const int = try reader.readInt(@typeInfo(PacketId).@"enum".tag_type, .big);
        const packet_id = std.meta.intToEnum(PacketId, int) catch {
            log.err("unknown packed {x}", .{int});
            return error.UnknownPacket;
        };

        log.debug("got packet {s}", .{@tagName(packet_id)});
        switch (packet_id) {
            inline else => |id| blk: {
                const T = @FieldType(Packet, @tagName(id));
                var result: T = undefined;

                if (T == void) break :blk;

                inline for (@typeInfo(T).@"struct".fields) |field| {
                    const F = @FieldType(T, field.name);

                    switch (F) {
                        EntityMetadata => {
                            var metadata: EntityMetadata = @splat(.empty);
                            while (true) {
                                const item = try reader.readByte();
                                if (item == 0x7F) break;
                                const index = item & 0x1F;
                                const @"type" = item >> 5;

                                if (@"type" == 0) metadata[index] = .{ .byte = try reader.readByte() };
                                if (@"type" == 1) metadata[index] = .{ .short = try reader.readInt(u16, .big) };
                                if (@"type" == 2) metadata[index] = .{ .int = try reader.readInt(u32, .big) };
                                if (@"type" == 3) metadata[index] = .{ .float = @bitCast(try reader.readInt(u32, .big)) };
                                if (@"type" == 4) metadata[index] = .{ .string = .{ .utf8 = try readString(reader, arena) } };
                                if (@"type" == 5) metadata[index] = .{ .slot = try Slot.parse(reader) };
                                if (@"type" == 6) {
                                    metadata[index] = .{ .pos = .{
                                        .x = try reader.readInt(i32, .big),
                                        .y = try reader.readInt(i32, .big),
                                        .z = try reader.readInt(i32, .big),
                                    } };
                                }
                            }
                            @field(result, field.name) = metadata;
                        },
                        String => {
                            @field(result, field.name) = .fromUtf8(try readString(reader, arena));
                            log.debug("read string {s}", .{@field(result, field.name).utf8});
                            // }
                        },
                        []const String => {
                            const len = @field(result, std.mem.trimLeft(u8, field.name, "_") ++ "_len");
                            const strings = try arena.alloc(String, len);
                            for (strings) |*string| {
                                string.* = .{ .utf8 = try readString(reader, arena) };
                            }
                            @field(result, field.name) = strings;
                        },
                        []const u8 => {
                            const len = @field(result, std.mem.trimLeft(u8, field.name, "_") ++ "_len");
                            const buffer = try arena.alloc(u8, @intCast(len));
                            _ = try reader.readAll(buffer);
                            @field(result, field.name) = buffer;
                        },
                        ?Slot => {
                            @field(result, field.name) = try Slot.parse(reader);
                        },
                        []const ?Slot => {
                            const len = @field(result, std.mem.trimLeft(u8, field.name, "_") ++ "_len");
                            const slots = try arena.alloc(?Slot, len);
                            for (slots) |*slot| {
                                slot.* = try Slot.parse(reader);
                            }
                            @field(result, field.name) = slots;
                        },
                        else => {
                            switch (@typeInfo(F)) {
                                .int => {
                                    @field(result, field.name) = try reader.readInt(F, .big);
                                    log.debug("{s}: {d}", .{ field.name, @field(result, field.name) });
                                },
                                .@"enum" => {
                                    @field(result, field.name) = try reader.readEnum(F, .big);
                                },
                                .float => |f| {
                                    @field(result, field.name) = @bitCast(try reader.readInt(@Type(.{
                                        .int = .{ .bits = f.bits, .signedness = .unsigned },
                                    }), .big));
                                    log.debug("{s}: {d}", .{ field.name, @field(result, field.name) });
                                },
                                .bool => {
                                    @field(result, field.name) = try reader.readInt(u8, .big) != 0;
                                    log.debug("{s}: {}", .{ field.name, @field(result, field.name) });
                                },
                                .@"struct" => |s| {
                                    comptime std.debug.assert(s.layout == .@"packed");
                                    @field(result, field.name) = try reader.readStruct(F);
                                },
                                .pointer => |p| {
                                    const CT = p.child;
                                    const layout = @typeInfo(CT).@"struct".layout;
                                    comptime std.debug.assert(p.size == .slice);

                                    const len = @field(result, field.name ++ "_len");
                                    const children = try arena.alloc(CT, len);
                                    _ = try reader.readAll(@ptrCast(children));
                                    for (children) |*child| {
                                        switch (layout) {
                                            .@"extern" => std.mem.byteSwapAllFields(CT, child),
                                            .@"packed" => {},
                                            else => comptime unreachable,
                                        }
                                    }
                                    @field(result, field.name) = children;
                                },
                                else => {
                                    @compileLog(T, F);
                                    comptime unreachable;
                                },
                            }
                        },
                    }
                }

                return @unionInit(Packet, @tagName(id), result);
            },
        }
        unreachable;
    }

    pub fn write(packet: Packet, writer: anytype) !void {
        log.debug("sending {s}", .{@tagName(packet)});
        @setEvalBranchQuota(2000);
        try writer.writeInt(u8, @intFromEnum(packet), .big);
        switch (packet) {
            inline else => |content| blk: {
                const T = @TypeOf(content);
                if (T == void) break :blk;

                inline for (@typeInfo(@TypeOf(content)).@"struct".fields) |field| {
                    const value = @field(content, field.name);
                    const F = @FieldType(T, field.name);

                    switch (F) {
                        String => {
                            try writeString(writer, value.utf8);
                        },
                        []const u8 => {
                            try writer.writeAll(value);
                        },
                        ?Slot => unreachable,
                        bool => {
                            try writer.writeByte(@intFromBool(value));
                        },
                        f32, f64 => {
                            try writer.writeAll(&std.mem.toBytes(value));
                        },
                        else => {
                            switch (@typeInfo(F)) {
                                .int => {
                                    try writer.writeInt(@TypeOf(value), value, .big);
                                },
                                .@"enum" => {
                                    try writer.writeInt(@TypeOf(@intFromEnum(value)), @intFromEnum(value), .big);
                                },
                                else => {
                                    // @compileLog(e);
                                    unreachable;
                                },
                            }
                        },
                    }

                    if (@typeInfo(@TypeOf(value)) == .int) {}
                }
            },
        }
    }
};

fn writeRawString(writer: anytype, str_be: []const u16) !void {
    try writer.writeInt(u16, @intCast(str_be.len), .big);
    try writer.writeAll(@ptrCast(str_be));
}

fn swapU16Slice(slice: []u16) void {
    for (slice) |*b| {
        b.* = @byteSwap(b.*);
    }
}

fn writeString(writer: anytype, string: []const u8) !void {
    var buffer: [0x100]u16 = undefined;
    const size: u16 = @intCast(std.unicode.utf8ToUtf16Le(&buffer, string) catch unreachable);
    swapU16Slice(buffer[0..size]);
    try writeRawString(writer, buffer[0..size]);
}

fn skipString(reader: anytype) !void {
    const size = try reader.readInt(u16, .big);
    try reader.skipBytes(size * 2, .{});
}

fn readRawString(reader: anytype, alloc: std.mem.Allocator) ![]u16 {
    const size = try reader.readInt(u16, .big);
    const buffer = try alloc.alloc(u16, size);
    errdefer alloc.free(buffer);
    _ = try reader.readAll(@ptrCast(buffer));
    return buffer;
}

fn readString(reader: anytype, alloc: std.mem.Allocator) ![]const u8 {
    const raw_string = try readRawString(reader, alloc);
    defer alloc.free(raw_string);
    swapU16Slice(raw_string);

    return try std.unicode.utf16LeToUtf8Alloc(alloc, raw_string);
}
