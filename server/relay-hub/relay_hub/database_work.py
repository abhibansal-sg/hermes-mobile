from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from typing import Callable, ParamSpec, TypeVar


class DatabaseBusy(RuntimeError):
    """The bounded database worker pool could not accept more work in time."""


_P = ParamSpec("_P")
_R = TypeVar("_R")


class DatabaseWorkPool:
    """Run complete synchronous storage operations outside the event loop.

    A permit is acquired before work is submitted to the dedicated executor, so
    its otherwise-unbounded internal queue never contains more work than there
    are workers.  The completion callback retains that permit until the worker
    has actually stopped, including when the awaiting request is cancelled.
    """

    def __init__(self, *, max_concurrency: int, acquire_timeout_seconds: float) -> None:
        self._acquire_timeout_seconds = acquire_timeout_seconds
        self._permits = asyncio.BoundedSemaphore(max_concurrency)
        self._executor = ThreadPoolExecutor(
            max_workers=max_concurrency,
            thread_name_prefix="relay-hub-db",
        )
        self._closed = False

    async def run(
        self, function: Callable[_P, _R], /, *args: _P.args, **kwargs: _P.kwargs
    ) -> _R:
        if self._closed:
            raise DatabaseBusy("database worker pool is closed")
        try:
            async with asyncio.timeout(self._acquire_timeout_seconds):
                await self._permits.acquire()
        except TimeoutError as exc:
            raise DatabaseBusy("database worker capacity exhausted") from exc

        if self._closed:
            self._permits.release()
            raise DatabaseBusy("database worker pool is closed")

        loop = asyncio.get_running_loop()
        try:
            future = loop.run_in_executor(
                self._executor,
                partial(function, *args, **kwargs),
            )
        except BaseException:
            self._permits.release()
            raise

        # Shielding prevents request cancellation from marking the executor
        # future complete while its SQL transaction is still running.
        future.add_done_callback(lambda _future: self._permits.release())
        return await asyncio.shield(future)

    async def shutdown(self) -> None:
        self._closed = True
        await asyncio.to_thread(
            self._executor.shutdown,
            wait=True,
            cancel_futures=False,
        )
