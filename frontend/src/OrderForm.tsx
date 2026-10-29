import { useState, type FormEvent } from "react";
import { createOrder, type Order, type Product } from "./api";

interface Props {
  products: Product[];
}

export default function OrderForm({ products }: Props) {
  const [productId, setProductId] = useState<number | null>(null);
  const [quantity, setQuantity] = useState(1);
  const [placed, setPlaced] = useState<Order | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Default to the first product once the list has loaded.
  const firstProduct: Product | undefined = products[0];
  const selectedId = productId ?? firstProduct?.id;

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (selectedId === undefined) return;

    setSubmitting(true);
    setError(null);
    try {
      // The backend answers 202 Accepted with the order still PENDING;
      // the orders table below shows it switching to CONFIRMED / FAILED.
      const response = await createOrder(selectedId, quantity);
      setPlaced(response.data);
    } catch (e) {
      setPlaced(null);
      setError((e as Error).message);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <section className="card">
      <h2>Place order</h2>
      <form onSubmit={handleSubmit} className="order-form">
        <label>
          Product
          <select value={selectedId ?? ""} onChange={(e) => setProductId(Number(e.target.value))}>
            {products.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Quantity
          <input
            type="number"
            min={1}
            value={quantity}
            onChange={(e) => setQuantity(Number(e.target.value))}
          />
        </label>
        <button type="submit" disabled={submitting || selectedId === undefined}>
          {submitting ? "Sending…" : "Place order"}
        </button>
      </form>

      {error && <p className="error">{error}</p>}
      {placed && (
        <p className="result">
          Order <strong>#{placed.id}</strong> accepted with status{" "}
          <span className={`status status-${placed.status.toLowerCase()}`}>{placed.status}</span>
        </p>
      )}
    </section>
  );
}
