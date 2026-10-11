// JSON-RPC over MCP Streamable HTTP for tests: builds requests and reads either a JSON or an SSE response.

export const ACCEPT = 'application/json, text/event-stream'
export const PROTOCOL_VERSION = '2025-06-18'

export interface RpcMessage {
  jsonrpc: '2.0'
  id?: number | string
  // deno-lint-ignore no-explicit-any
  result?: any
  error?: { code: number; message: string }
}

export function rpcBody(
  id: number,
  method: string,
  params?: Record<string, unknown>,
): Record<string, unknown> {
  return { jsonrpc: '2.0', id, method, ...(params ? { params } : {}) }
}

export const initializeBody = (id = 1) =>
  rpcBody(id, 'initialize', {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {},
    clientInfo: { name: 'gymrollins-test', version: '0' },
  })

export const toolCallBody = (id: number, name: string, args: Record<string, unknown> = {}) =>
  rpcBody(id, 'tools/call', { name, arguments: args })

export function rpcRequest(url: string, body: unknown, token?: string): Request {
  return new Request(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: ACCEPT,
      'mcp-protocol-version': PROTOCOL_VERSION,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  })
}

/** The JSON-RPC response in a JSON body, or the last `data:` message carrying an id in an SSE body. */
export async function readRpc(res: Response): Promise<RpcMessage> {
  const text = await res.text()
  if (!(res.headers.get('content-type') ?? '').includes('text/event-stream')) return JSON.parse(text)
  const messages = text.split('\n')
    .filter((line) => line.startsWith('data:'))
    .map((line) => JSON.parse(line.slice(5).trim()) as RpcMessage)
    .filter((m) => m.id !== undefined)
  if (messages.length === 0) throw new Error(`no JSON-RPC response in SSE body: ${text.slice(0, 200)}`)
  return messages[messages.length - 1]
}

/** Parses the JSON text content of a tools/call result. */
// deno-lint-ignore no-explicit-any
export function toolJson(msg: RpcMessage): any {
  return JSON.parse(msg.result.content[0].text)
}
