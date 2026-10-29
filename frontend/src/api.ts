// All calls to the backend live in this file.
//
// VITE_API_URL is read at build time. When it is not set, BASE is "/api/v1",
// so the browser calls the same host that served the page (e.g. nginx proxying /api).
const BASE = `${import.meta.env.VITE_API_URL ?? ""}/api/v1`;

export type OrderStatus = "PENDING" | "CONFIRMED" | "FAILED";

export interface Product {
  id: number;
  name: string;
  price: number;
  stock: number;
}

export interface Order {
  id: number;
  productId: number;
  quantity: number;
  status: OrderStatus;
  createdAt: string;
  processedAt: string | null;
  processedBy: string | null;
}

/** Response body plus the custom headers the backend sends. */
export interface ApiResponse<T> {
  data: T;
  /** X-Cache: "HIT" or "MISS" (only on GET /products). */
  cache: string | null;
  /** X-Instance: hostname of the backend that answered. */
  instance: string | null;
}

// Every response reports which backend instance answered; the footer listens for it.
type InstanceListener = (instance: string) => void;
let instanceListener: InstanceListener | null = null;

export function onInstance(listener: InstanceListener | null) {
  instanceListener = listener;
}

async function request<T>(path: string, init?: RequestInit): Promise<ApiResponse<T>> {
  const response = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers },
  });

  const instance = response.headers.get("X-Instance");
  if (instance && instanceListener) {
    instanceListener(instance);
  }

  if (!response.ok) {
    // The backend returns errors as JSON: { "error": "...", "message": "..." }
    const body = await response.json().catch(() => null);
    throw new Error(body?.message ?? `HTTP ${response.status}`);
  }

  return {
    data: (await response.json()) as T,
    cache: response.headers.get("X-Cache"),
    instance,
  };
}

export function getProducts() {
  return request<Product[]>("/products");
}

export function getOrders() {
  return request<Order[]>("/orders");
}

export function createOrder(productId: number, quantity: number) {
  return request<Order>("/orders", {
    method: "POST",
    body: JSON.stringify({ productId, quantity }),
  });
}
