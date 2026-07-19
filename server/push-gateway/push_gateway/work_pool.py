from __future__ import annotations

import asyncio
import functools
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, TypeVar


_T = TypeVar("_T")


class WorkPoolSaturated(RuntimeError):
    pass


class BoundedWorkPool:
    """A non-queuing admission gate in front of a dedicated executor.

    At most ``limit`` calls can be submitted, which bounds both running work
    and the executor's otherwise-unbounded internal queue.  Cancellation does
    not release admission until the synchronous function has really exited.
    """

    def __init__(self, limit: int, *, thread_name_prefix: str) -> None:
        if limit <= 0:
            raise ValueError("work-pool limit must be positive")
        self._limit = limit
        self._active = 0
        self._closed = False
        self._lock = asyncio.Lock()
        self._owners: set[asyncio.Task[Any]] = set()
        self._executor = ThreadPoolExecutor(
            max_workers=limit,
            thread_name_prefix=thread_name_prefix,
        )

    async def _try_acquire(self) -> bool:
        async with self._lock:
            if self._closed or self._active >= self._limit:
                return False
            self._active += 1
            return True

    async def _release(self) -> None:
        async with self._lock:
            if self._active <= 0:
                raise RuntimeError("work-pool admission released without an owner")
            self._active -= 1

    async def run(
        self, function: Callable[..., _T], /, *args: Any, **kwargs: Any
    ) -> _T:
        if not await self._try_acquire():
            raise WorkPoolSaturated
        try:
            call = functools.partial(function, *args, **kwargs)
            future = asyncio.get_running_loop().run_in_executor(self._executor, call)
        except BaseException:
            await self._release()
            raise

        async def own_admission() -> _T:
            try:
                return await future
            finally:
                # This task is shielded from caller cancellation and is the
                # sole owner of admission after submission.  Even repeated
                # cancellation of the request cannot release the slot early.
                await self._release()

        owner = asyncio.create_task(own_admission())
        self._owners.add(owner)

        def completed(task: asyncio.Task[Any]) -> None:
            self._owners.discard(task)
            if not task.cancelled():
                # Retrieve background exceptions when the request that would
                # normally observe them was cancelled.
                task.exception()

        owner.add_done_callback(completed)
        return await asyncio.shield(owner)

    async def close(self) -> None:
        async with self._lock:
            if self._closed:
                return
            self._closed = True
        await asyncio.to_thread(self._executor.shutdown, True)
        owners = tuple(self._owners)
        if owners:
            await asyncio.gather(*owners, return_exceptions=True)
