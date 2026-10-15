/*
 * Copyright (c) 2022 EKA2L1 Team
 * 
 * This file is part of EKA2L1 project
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

#include <services/audio/alf/alf.h>
#include <system/epoc.h>

#include <utils/err.h>

#include <common/algorithm.h>
#include <common/cvt.h>
#include <common/log.h>
#include <common/path.h>
#include <kernel/codeseg.h>
#include <kernel/kernel.h>
#include <kernel/libmanager.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <services/window/classes/winbase.h>
#include <services/window/screen.h>
#include <services/window/window.h>

#include <cstring>

namespace eka2l1 {
    alf_streamer_server::alf_streamer_server(eka2l1::system *sys)
        : service::typical_server(sys, "alfstreamerserver") {
        kernel_system *kern = sys->get_kernel_system();

        // On NGA hardware the Alf server is a thread that alfrenderstage starts
        // inside the window server. EKA2L1's window server is HLE, so nothing
        // starts it. Remember each process that links alfclient.dll and start the
        // ROM's own server thread in the first of them at its next IPC send, after
        // its DLLs are initialised and well before CAlfEnv::NewL looks it up.
        kern->register_codeseg_loaded_callback([this](const std::string &lib_name, kernel::process *attacher, codeseg_ptr) {
            if (!attacher) {
                return;
            }

            // Codeseg names look like "alfclient.dll" or "alfclient{000a0000}..."
            std::string base = eka2l1::filename(lib_name, true);
            base = base.substr(0, base.find_first_of(".{["));
            if (common::compare_ignore_case(base.c_str(), "alfclient") != 0) {
                return;
            }

            alf_client_processes_.insert(attacher->unique_id());
        });

        kern->register_ipc_send_callback([this](const std::string &, const int, const ipc_arg &, address, kernel::thread *sender) {
            if (alf_host_process_ || !sender) {
                return;
            }

            kernel::process *pr = sender->owning_process();
            if (!pr || (alf_client_processes_.count(pr->unique_id()) == 0)) {
                return;
            }

            alf_host_process_ = pr->unique_id();
            boot_alf_server_thread(pr);
        });

        // TEMP diagnostics for the Alf bring-up.
        kern->register_thread_kill_callback([this](kernel::thread *thr, const std::string &category, const std::int32_t reason) {
            const std::string name = thr->name();
            if ((name.find("alf") != std::string::npos) || (thr->owning_process() && (thr->owning_process()->unique_id() == alf_host_process_))) {
                LOG_WARN(SERVICE_UI, "Alf boot: thread {} exited, category {}, reason {}", name, category, reason);
            }
        });

        // On NGA the Alf server is the compositor, so its full-screen window sits at
        // the back (ECoeWinPriorityNeverAtFront) and WServ never draws over it. Here
        // WServ composes, so put the Alf window in front while any client shows an
        // Alf control group, and back behind the apps when the last one is hidden.
        kern->register_ipc_send_callback([this](const std::string &server_name, const int ord, const ipc_arg &, address, kernel::thread *) {
            static constexpr int EALF_ROSTER_SHOW = 2000;
            static constexpr int EALF_ROSTER_HIDE = 2001;

            if ((ord != EALF_ROSTER_SHOW) && (ord != EALF_ROSTER_HIDE)) {
                return;
            }

            if (server_name.find("10282845_AppServer") == std::string::npos) {
                return;
            }

            const std::int32_t before = shown_control_groups_;
            shown_control_groups_ = common::max<std::int32_t>(0, shown_control_groups_ + ((ord == EALF_ROSTER_SHOW) ? 1 : -1));

            LOG_WARN(SERVICE_UI, "Alf boot: roster {} -> {} shown control groups", (ord == EALF_ROSTER_SHOW) ? "show" : "hide", shown_control_groups_);

            if ((before == 0) != (shown_control_groups_ == 0)) {
                bring_alf_window_to_front(shown_control_groups_ != 0);
            }
        });

        kern->register_process_exit_callback([this](kernel::process *pr) {
            alf_client_processes_.erase(pr->unique_id());

            // The server thread dies with its host. Start it again in the next
            // Alf client that talks to anyone.
            if (alf_host_process_ == pr->unique_id()) {
                alf_host_process_ = 0;
                shown_control_groups_ = 0;
            }
        });
    }

    void alf_streamer_server::bring_alf_window_to_front(const bool front) {
        static constexpr std::int32_t ALF_FRONT_PRIORITY = 1000;     // ECoeWinPriorityAlwaysAtFront
        static constexpr std::int32_t ALF_BACK_PRIORITY = -1000;     // ECoeWinPriorityNeverAtFront

        kernel_system *kern = sys->get_kernel_system();
        window_server *winserv = reinterpret_cast<window_server *>(kern->get_by_name<service::server>(
            get_winserv_name_by_epocver(kern->get_epoc_version())));

        if (!winserv) {
            return;
        }

        for (epoc::screen *scr = winserv->get_screens(); scr; scr = scr->next) {
            for (epoc::window *group = scr->root->child; group; group = group->sibling) {
                if ((group->type != epoc::window_kind::group) || !group->client || !group->client->get_client() ||
                    (group->client->get_client()->name() != "alfredserver")) {
                    continue;
                }

                group->priority = front ? ALF_FRONT_PRIORITY : ALF_BACK_PRIORITY;
                group->move_window(group->parent, 0);
                scr->update_focus(winserv, nullptr);

                LOG_WARN(SERVICE_UI, "Alf boot: Alf window group moved to the {}", front ? "front" : "back");
                break;
            }
        }
    }

    void alf_streamer_server::boot_alf_server_thread(kernel::process *pr) {
        kernel_system *kern = sys->get_kernel_system();
        hle::lib_manager *libmngr = kern->get_lib_manager();

        codeseg_ptr seg = libmngr->load(u"alfdecoderserverclient.dll");
        if (!seg) {
            LOG_ERROR(SERVICE_UI, "Alf boot: can't load alfdecoderserverclient.dll");
            return;
        }

        seg->attach(pr);
        seg->attached_report(pr);

        // AlfThreadFucntion isn't exported. AlfServerStarter::StartL (ordinal 13)
        // passes it to RThread::Create, so its address is in StartL's literal pool:
        // the one code pointer whose target starts with an STMFD/PUSH {.., lr}.
        static constexpr std::uint32_t START_L_ORDINAL = 13;
        const address start_l = seg->lookup(pr, START_L_ORDINAL);
        const address code_base = seg->get_code_run_addr(pr);
        const address code_end = code_base + seg->get_code_size();

        if (!start_l) {
            LOG_ERROR(SERVICE_UI, "Alf boot: AlfServerStarter::StartL not found");
            return;
        }

        auto read_word = [&](const address addr, std::uint32_t &value) {
            const void *host = pr->get_ptr_on_addr_space(addr);
            if (!host) {
                return false;
            }

            std::memcpy(&value, host, sizeof(std::uint32_t));
            return true;
        };

        address thread_func = 0;
        const address scan_start = start_l & ~3u;

        for (address addr = scan_start; addr < common::min<address>(scan_start + 0x400, code_end); addr += 4) {
            std::uint32_t word = 0;
            if (!read_word(addr, word)) {
                break;
            }

            const address target = word & ~1u;
            if ((target < code_base) || (target >= code_end) || (target == (start_l & ~1u))) {
                continue;
            }

            std::uint32_t first_insn = 0;
            if (!read_word(target, first_insn)) {
                continue;
            }

            const bool arm_push_lr = ((word & 1) == 0) && ((first_insn & 0xFFFF4000) == 0xE92D4000);
            const bool thumb_push_lr = ((word & 1) == 1) && ((first_insn & 0xFF00) == 0xB500);

            if (arm_push_lr || thumb_push_lr) {
                thread_func = word;
                break;
            }
        }

        if (!thread_func) {
            LOG_ERROR(SERVICE_UI, "Alf boot: AlfThreadFucntion not found near StartL 0x{:X}", start_l);
            return;
        }

        // Same parameters RThread::Create gets in AlfServerStarter::StartL.
        static constexpr std::size_t ALF_STACK_SIZE = 16384;
        static constexpr std::size_t ALF_HEAP_MIN = 4 * 1024 * 1024;
        static constexpr std::size_t ALF_HEAP_MAX = 10 * 1024 * 1024;

        auto result = kern->create_and_add<kernel::thread>(kernel::owner_type::process, kern->get_memory_system(),
            kern->get_ntimer(), pr, kernel::access_type::local_access, "alfredserver", thread_func,
            ALF_STACK_SIZE, ALF_HEAP_MIN, ALF_HEAP_MAX, false, 0, 0, kernel::thread_priority::priority_normal);

        if (!result.second) {
            LOG_ERROR(SERVICE_UI, "Alf boot: can't create the alfredserver thread");
            return;
        }

        LOG_WARN(SERVICE_UI, "Alf boot: starting alfredserver in {} at 0x{:X}", pr->name(), thread_func);
        result.second->resume();
    }

    void alf_streamer_server::connect(service::ipc_context &context) {
        create_session<alf_streamer_session>(&context);
        context.complete(epoc::error_none);
    }

    alf_streamer_session::alf_streamer_session(service::typical_server *serv, const kernel::uid ss_id,
        epoc::version client_version)
        : service::typical_session(serv, ss_id, client_version) {
    }

    void alf_streamer_session::fetch(service::ipc_context *ctx) {
        int function = ctx->msg->function;
        if ((function >= 20000) && (function <= 20005)) {
            function -= 20000;
        }

        switch (function) {
        case 2: {
            // Synchronous effect-plugin calls return a serialized TInt error
            // in argument 2. Effects are intentionally disabled, so success
            // is sufficient for all no-op transition commands.
            const std::int32_t result = epoc::error_none;
            ctx->write_data_to_descriptor_argument(2, result);
            ctx->complete(epoc::error_none);
            break;
        }
        case 3:
            // This is a long-lived transition-policy notification. The client
            // fetches policy data only after the request is completed.
            if (pending_plugin_request_) {
                pending_plugin_request_->complete(epoc::error_cancel);
            }
            pending_plugin_request_ = ctx->move_to_new();
            break;
        case 4:
            if (pending_plugin_request_) {
                pending_plugin_request_->complete(epoc::error_cancel);
                pending_plugin_request_.reset();
            }
            ctx->complete(epoc::error_none);
            break;
        default:
            ctx->complete(epoc::error_none);
            break;
        }
    }
}
