import { useEffect, useState } from "react";
import { getOrders, type Order, type Product } from "./api";

const POLL_INTERVAL_MS = 2000;

interface Props {
  /** Used to show product names instead of ids. */
  products: Product[];
}

export default function OrdersTable({ products }: Props) {
  const [orders, setOrders] = useState<Order[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Poll the backend every 2 seconds so PENDING orders visibly turn CONFIRMED / FAILED.
  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        const response = await getOrders();
        if (!cancelled) {
          setOrders(response.data);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError((e as Error).message);
      }
    }

    load();
    const timer = setInterval(load, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, []);

  const productName = (id: number) => products.find((p) => p.id === id)?.name ?? `#${id}`;

  return (
    <section className="card">
      <div className="card-header">
        <h2>Orders</h2>
        <span className="hint">refreshes every {POLL_INTERVAL_MS / 1000}s</span>
      </div>

      {error && <p className="error">Could not load orders: {error}</p>}

      <table>
        <thead>
          <tr>
            <th className="num">Id</th>
            <th>Product</th>
            <th className="num">Quantity</th>
            <th>Status</th>
            <th>Processed by</th>
          </tr>
        </thead>
        <tbody>
          {orders.length === 0 && (
            <tr>
              <td colSpan={5} className="empty">
                No orders yet
              </td>
            </tr>
          )}
          {orders.map((o) => (
            <tr key={o.id}>
              <td className="num">{o.id}</td>
              <td>{productName(o.productId)}</td>
              <td className="num">{o.quantity}</td>
              <td>
                <span className={`status status-${o.status.toLowerCase()}`}>{o.status}</span>
              </td>
              <td>
                <code>{o.processedBy ?? "–"}</code>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
