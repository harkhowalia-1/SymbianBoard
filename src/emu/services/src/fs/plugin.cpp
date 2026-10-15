/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

// File server plugins.
//
// Real file server plugins are native DLLs loaded into the file server's own
// process, which the HLE file server can't host. The one that matters is the
// Metadata System's (mdsfileserverplugin, position 0x200071CD): the media
// harvester learns about new, changed and removed files through it, and that is
// what fills Gallery, Music and friends. It is emulated here: the harvester
// gets a plugin subsession, and file operations made through this server (or
// reported by the host for files it drops onto a drive) come back to it as
// TMdsFSPStatus events. Every other plugin is accepted but does nothing.

#include <services/fs/fs.h>
#include <services/context.h>

#include <common/algorithm.h>
#include <common/cvt.h>
#include <common/log.h>
#include <common/path.h>

#include <kernel/kernel.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <system/epoc.h>
#include <utils/err.h>

#include <cstring>

namespace eka2l1 {
    static constexpr std::int32_t MDS_FS_PLUGIN_POSITION = 0x200071CD;
    static constexpr std::size_t MDS_MAX_QUEUED_EVENTS = 4096;

    // TMdsFSPOperation (mdsfileserverpluginclient.h).
    enum mds_fsp_operation {
        mds_fsp_op_enable = 0,
        mds_fsp_op_disable = 1,
        mds_fsp_op_register_notification = 2,
        mds_fsp_op_add_notification_path = 3,
        mds_fsp_op_remove_notification_path = 4,
        mds_fsp_op_add_ignore_path = 5,
        mds_fsp_op_remove_ignore_path = 6,
        mds_fsp_op_notification_cancel = 7
    };

    // TMdsFSPStatus as the guest lays it out: two TInts, two TFileNames
    // (TBuf16<256>: length/type word, max length, 256 UTF-16 units), the
    // process TUid and the drive's media id.
    static constexpr std::size_t MDS_FILENAME_SIZE = 8 + 256 * 2;
    static constexpr std::size_t MDS_STATUS_SIZE = 4 + 4 + MDS_FILENAME_SIZE * 2 + 4 + 4;

    static void write_tbuf16(std::uint8_t *dest, const std::u16string &str) {
        const std::uint32_t length = static_cast<std::uint32_t>(common::min<std::size_t>(str.size(), 256));
        // EBuf (3) in the descriptor type nibble.
        const std::uint32_t length_word = length | (3U << 28);
        const std::uint32_t max_length = 256;
        std::memcpy(dest, &length_word, 4);
        std::memcpy(dest + 4, &max_length, 4);
        std::memcpy(dest + 8, str.data(), length * sizeof(char16_t));
    }

    static std::vector<std::uint8_t> serialize_mds_event(const fs_server::mds_plugin_event &evt) {
        std::vector<std::uint8_t> data(MDS_STATUS_SIZE, 0);
        std::memcpy(data.data(), &evt.type, 4);
        std::memcpy(data.data() + 4, &evt.drive, 4);
        write_tbuf16(data.data() + 8, evt.name);
        write_tbuf16(data.data() + 8 + MDS_FILENAME_SIZE, evt.new_name);
        std::memcpy(data.data() + 8 + MDS_FILENAME_SIZE * 2, &evt.process_uid, 4);
        // The HLE server reports a drive's number as its volume unique id.
        const std::uint32_t media_id = static_cast<std::uint32_t>(evt.drive);
        std::memcpy(data.data() + 8 + MDS_FILENAME_SIZE * 2 + 4, &media_id, 4);
        return data;
    }

    // Only user content is worth harvesting: no ROM, no RAM drive, no private,
    // system or resource trees (the harvester ignores those anyway, and the
    // emulator's own databases churn there constantly).
    static bool is_harvestable_path(const std::u16string &path) {
        if (path.size() < 3 || path[1] != u':') {
            return false;
        }

        const char16_t drive = static_cast<char16_t>(std::towupper(path[0]));
        if ((drive == u'Z') || (drive == u'D')) {
            return false;
        }

        std::u16string lowered = common::lowercase_ucs2_string(path);
        static const char16_t *IGNORED[] = { u"\\private\\", u"\\sys\\", u"\\resource\\", u"\\system\\" };
        for (const char16_t *ignored : IGNORED) {
            if (lowered.compare(2, std::char_traits<char16_t>::length(ignored), ignored) == 0) {
                return false;
            }
        }

        return true;
    }

    void fs_server::report_file_event(const std::int32_t type, const std::u16string &path,
        const std::u16string &new_path, const std::uint32_t process_uid) {
        if (mds_plugin_sessions_.empty() || !is_harvestable_path(new_path.empty() ? path : new_path)) {
            return;
        }

        mds_plugin_event evt;
        evt.type = type;
        evt.drive = static_cast<std::int32_t>(std::towupper(path[0]) - u'A');
        evt.name = eka2l1::transform_separators<char16_t>(path, true, eka2l1::get_separator_16);
        evt.new_name = eka2l1::transform_separators<char16_t>(new_path, true, eka2l1::get_separator_16);
        evt.process_uid = process_uid;

        for (auto &[handle, session] : mds_plugin_sessions_) {
            if (!session.enabled) {
                continue;
            }
            if (session.events.size() >= MDS_MAX_QUEUED_EVENTS) {
                session.events.pop_front();
            }
            session.events.push_back(evt);
            deliver_mds_events(session);
        }
    }

    void fs_server::deliver_mds_events(mds_plugin_session &session) {
        if (!session.pending || session.events.empty()) {
            return;
        }

        const std::vector<std::uint8_t> data = serialize_mds_event(session.events.front());
        session.events.pop_front();

        std::unique_ptr<service::ipc_context> ctx = std::move(session.pending);
        ctx->write_data_to_descriptor_argument(1, data.data(), static_cast<std::uint32_t>(data.size()));
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_accept(service::ipc_context *ctx) {
        // AddPlugin / RemovePlugin / MountPlugin / DismountPlugin: plugins are
        // emulated in-server, so there is nothing to load or attach.
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_open(service::ipc_context *ctx) {
        const std::optional<std::int32_t> position = ctx->get_argument_value<std::int32_t>(0);
        if (!position || (position.value() != MDS_FS_PLUGIN_POSITION)) {
            ctx->complete(epoc::error_not_found);
            return;
        }

        fs_server *serv = server<fs_server>();
        const std::int32_t handle = serv->next_mds_plugin_handle_++;
        serv->mds_plugin_sessions_[handle];
        ctx->write_data_to_descriptor_argument<std::int32_t>(3, handle);
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_close(service::ipc_context *ctx) {
        const std::optional<std::int32_t> handle = ctx->get_argument_value<std::int32_t>(3);
        fs_server *serv = server<fs_server>();
        if (handle) {
            auto it = serv->mds_plugin_sessions_.find(handle.value());
            if (it != serv->mds_plugin_sessions_.end()) {
                if (it->second.pending) {
                    it->second.pending->complete(epoc::error_cancel);
                }
                serv->mds_plugin_sessions_.erase(it);
            }
        }
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_do_request(service::ipc_context *ctx) {
        const std::optional<std::int32_t> handle = ctx->get_argument_value<std::int32_t>(3);
        const std::optional<std::int32_t> op = ctx->get_argument_value<std::int32_t>(0);
        fs_server *serv = server<fs_server>();

        auto it = handle ? serv->mds_plugin_sessions_.find(handle.value()) : serv->mds_plugin_sessions_.end();
        if (it == serv->mds_plugin_sessions_.end() || !op) {
            ctx->complete(epoc::error_bad_handle);
            return;
        }

        if (op.value() == mds_fsp_op_register_notification) {
            if (it->second.pending) {
                ctx->complete(epoc::error_in_use);
                return;
            }
            it->second.pending = ctx->move_to_new();
            serv->deliver_mds_events(it->second);
            return;
        }

        // Path filters: the events are already limited to user content, and the
        // harvester filters again on its side.
        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_do_control(service::ipc_context *ctx) {
        const std::optional<std::int32_t> handle = ctx->get_argument_value<std::int32_t>(3);
        const std::optional<std::int32_t> op = ctx->get_argument_value<std::int32_t>(0);
        fs_server *serv = server<fs_server>();

        auto it = handle ? serv->mds_plugin_sessions_.find(handle.value()) : serv->mds_plugin_sessions_.end();
        if (it != serv->mds_plugin_sessions_.end() && op) {
            switch (op.value()) {
            case mds_fsp_op_enable:
                it->second.enabled = true;
                break;
            case mds_fsp_op_disable:
                it->second.enabled = false;
                it->second.events.clear();
                break;
            case mds_fsp_op_notification_cancel:
                if (it->second.pending) {
                    it->second.pending->complete(epoc::error_cancel);
                    it->second.pending.reset();
                }
                break;
            default:
                break;
            }
        }

        ctx->complete(epoc::error_none);
    }

    void fs_server_client::plugin_do_cancel(service::ipc_context *ctx) {
        const std::optional<std::int32_t> handle = ctx->get_argument_value<std::int32_t>(3);
        fs_server *serv = server<fs_server>();

        auto it = handle ? serv->mds_plugin_sessions_.find(handle.value()) : serv->mds_plugin_sessions_.end();
        if (it != serv->mds_plugin_sessions_.end() && it->second.pending) {
            it->second.pending->complete(epoc::error_cancel);
            it->second.pending.reset();
        }

        ctx->complete(epoc::error_none);
    }
}
