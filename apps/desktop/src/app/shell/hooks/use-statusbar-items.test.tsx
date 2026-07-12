import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { $primaryGatewayReconnecting } from '@/store/gateway'

import { useStatusbarItems } from './use-statusbar-items'

beforeEach(() => {
  $primaryGatewayReconnecting.set(false)
})

afterEach(() => {
  cleanup()
  $primaryGatewayReconnecting.set(false)
})

describe('useStatusbarItems gateway status', () => {
  it('renders reconnecting detail while primary gateway retries after boot', () => {
    const requestGateway = async <T = unknown>(
      _method: string,
      _params?: Record<string, unknown>
    ): Promise<T> => undefined as T

    const { result } = renderHook(() =>
      useStatusbarItems({
        agentsOpen: false,
        chatOpen: true,
        commandCenterOpen: false,
        extraLeftItems: [],
        extraRightItems: [],
        freshDraftReady: false,
        gatewayState: 'closed',
        inferenceStatus: null,
        openAgents: vi.fn(),
        openCommandCenterSection: vi.fn(),
        requestGateway,
        statusSnapshot: null,
        toggleCommandCenter: vi.fn()
      })
    )

    let gatewayItem = result.current.leftStatusbarItems.find(item => item.id === 'gateway-health')
    expect(gatewayItem?.detail).toBe('offline')

    act(() => {
      $primaryGatewayReconnecting.set(true)
    })

    gatewayItem = result.current.leftStatusbarItems.find(item => item.id === 'gateway-health')
    expect(gatewayItem?.detail).toBe('reconnecting…')
    expect(gatewayItem?.className).toBe('text-amber-600 hover:text-amber-600')
  })
})
