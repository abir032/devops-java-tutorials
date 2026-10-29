import type { Product } from "./api";

interface Props {
  products: Product[];
  /** Value of the X-Cache header: "HIT" (from Redis) or "MISS" (from MariaDB). */
  cache: string | null;
  error: string | null;
  onRefresh: () => void;
}

export default function ProductsTable({ products, cache, error, onRefresh }: Props) {
  return (
    <section className="card">
      <div className="card-header">
        <h2>Products</h2>
        {cache && (
          <span className={`badge cache-${cache.toLowerCase()}`} title="X-Cache response header">
            cache {cache}
          </span>
        )}
        <button onClick={onRefresh}>Refresh</button>
      </div>

      {error && <p className="error">Could not load products: {error}</p>}

      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th className="num">Price</th>
            <th className="num">Stock</th>
          </tr>
        </thead>
        <tbody>
          {products.map((p) => (
            <tr key={p.id}>
              <td>{p.name}</td>
              <td className="num">{p.price.toFixed(2)}</td>
              <td className="num">{p.stock}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
