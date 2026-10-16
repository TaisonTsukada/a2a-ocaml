import asyncio
import sys

import httpx
import uvicorn
from starlette.applications import Starlette

from a2a.helpers.proto_helpers import new_task_from_user_message
from a2a.server.agent_execution.agent_executor import AgentExecutor
from a2a.server.agent_execution.context import RequestContext
from a2a.server.events.event_queue import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes, create_rest_routes
from a2a.server.tasks.base_push_notification_sender import BasePushNotificationSender
from a2a.server.tasks.inmemory_push_notification_config_store import InMemoryPushNotificationConfigStore
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore
from a2a.server.tasks.task_updater import TaskUpdater
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill, Part


class Executor(AgentExecutor):
    async def execute(self, context: RequestContext, queue: EventQueue) -> None:
        message = context.message
        text = " ".join(p.text for p in message.parts if p.text) if message else ""
        word = text.split()[0] if text.split() else ""
        if context.current_task is None:
            await queue.enqueue_event(new_task_from_user_message(message))
        up = TaskUpdater(queue, context.task_id, context.context_id)
        if word == "input":
            await up.requires_input()
            return
        await up.start_work()
        if word == "slow":
            await asyncio.sleep(3)
        await up.add_artifact(parts=[Part(text="done: " + text)])
        await up.complete()

    async def cancel(self, context: RequestContext, queue: EventQueue) -> None:
        await TaskUpdater(queue, context.task_id, context.context_id).cancel()


def card(port: int, name: str, extended: bool) -> AgentCard:
    base = f"http://127.0.0.1:{port}"
    return AgentCard(
        name=name, description="a2a-sdk 1.x interop target", version="1.0.0",
        supported_interfaces=[
            AgentInterface(url=base, protocol_binding="JSONRPC", protocol_version="1.0"),
            AgentInterface(url=base + "/rest", protocol_binding="HTTP+JSON", protocol_version="1.0"),
        ],
        capabilities=AgentCapabilities(streaming=True, push_notifications=True, extended_agent_card=True),
        default_input_modes=["text/plain"], default_output_modes=["text/plain"],
        skills=[AgentSkill(id="test", name="test", description="test", tags=["test"])]
        + ([AgentSkill(id="secret", name="secret", description="for authenticated clients", tags=["test"])]
           if extended else []),
    )


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9995
    public = card(port, "v1 test agent", extended=False)
    store = InMemoryPushNotificationConfigStore()
    handler = DefaultRequestHandler(
        agent_executor=Executor(), task_store=InMemoryTaskStore(), agent_card=public,
        push_config_store=store,
        push_sender=BasePushNotificationSender(httpx.AsyncClient(), store),
        extended_agent_card=card(port, "v1 test agent (extended)", extended=True),
    )
    app = Starlette(routes=[
        *create_jsonrpc_routes(request_handler=handler, rpc_url="/"),
        *create_agent_card_routes(agent_card=public),
        *create_rest_routes(request_handler=handler, path_prefix="/rest"),
    ])
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
