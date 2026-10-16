import asyncio
import base64
import sys

import uvicorn
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.apps import A2AStarletteApplication
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import (
    AgentCapabilities, AgentCard, AgentSkill, DataPart, FilePart,
    FileWithBytes, FileWithUri, Part, TaskState, TextPart,
)
from a2a.utils import new_agent_text_message, new_task


class Executor(AgentExecutor):
    async def execute(self, context: RequestContext, queue: EventQueue) -> None:
        text = context.get_user_input()
        word = text.split()[0] if text.split() else ""
        if word == "message":
            await queue.enqueue_event(new_agent_text_message("Direct: " + text))
            return
        task = context.current_task
        if task is None:
            task = new_task(context.message)
            await queue.enqueue_event(task)
        up = TaskUpdater(queue, task.id, task.context_id)
        say = lambda s: new_agent_text_message(s, task.context_id, task.id)
        if word == "input" and task.status.state != TaskState.input_required:
            await up.update_status(TaskState.input_required, say("Where to?"), final=True)
            return
        if word == "fail":
            await up.failed(say("it broke"))
            return
        await up.start_work(say("working"))
        if word == "slow":
            await asyncio.sleep(3)
        if word == "echo":
            await up.add_artifact(context.message.parts, artifact_id="echo", name="echo")
        else:
            await up.add_artifact([Part(root=TextPart(text="chunk-1 "))], artifact_id="a1",
                                  name="text", append=False, last_chunk=False)
            await up.add_artifact([Part(root=TextPart(text="chunk-2"))], artifact_id="a1",
                                  append=True, last_chunk=True)
            await up.add_artifact([
                Part(root=FilePart(file=FileWithBytes(
                    bytes=base64.b64encode(b"\x00tck\xff").decode(), name="o.bin",
                    mime_type="application/octet-stream"))),
                Part(root=FilePart(file=FileWithUri(uri="https://example.com/o.txt"))),
                Part(root=DataPart(data={"key": "value"})),
            ], artifact_id="f1", name="files")
        await up.complete(say("done"))

    async def cancel(self, context: RequestContext, queue: EventQueue) -> None:
        await TaskUpdater(queue, context.task_id, context.context_id).cancel()


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9993
    card = AgentCard(
        name="v0.3 test agent", description="a2a-sdk 0.3 interop target",
        url=f"http://127.0.0.1:{port}/", version="1.0.0",
        default_input_modes=["text/plain"], default_output_modes=["text/plain"],
        capabilities=AgentCapabilities(streaming=True),
        skills=[AgentSkill(id="test", name="test", description="test", tags=["test"])],
    )
    handler = DefaultRequestHandler(agent_executor=Executor(), task_store=InMemoryTaskStore())
    app = A2AStarletteApplication(agent_card=card, http_handler=handler).build()
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
