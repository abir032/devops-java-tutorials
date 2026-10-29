import { useCallback, useEffect, useState } from "react";
import { getProducts, onInstance, type Product } from "./api";
import ProductsTable from "./ProductsTable";
import OrderForm from "./OrderForm";
import OrdersTable from "./OrdersTable";

export default function App() {
  const [products, setProducts] = useState<Product[]>([]);
  const [cache, setCache] = useState<string | null>(null);
  const [productsError, setProductsError] = useState<string | null>(null);
  const [instance, setInstance] = useState<string | null>(null);

  // Remember the X-Instance header of the most recent response (shown in the footer).
  useEffect(() => {
    onInstance(setInstance);
    return () => onInstance(null);
  }, []);

  const loadProducts = useCallback(async () => {
    try {
      const response = await getProducts();
      setProducts(response.data);
      setCache(response.cache);
      setProductsError(null);
    } catch (e) {
      setProductsError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    loadProducts();
  }, [loadProducts]);

  return (
    <div className="page">
      <header>
        <h1>Order Desk</h1>
        <p className="subtitle">React → Spring Boot → MariaDB / Redis / RabbitMQ</p>
      </header>

      <main>
        <ProductsTable
          products={products}
          cache={cache}
          error={productsError}
          onRefresh={loadProducts}
        />
        <OrderForm products={products} />
        <OrdersTable products={products} />
      </main>

      <footer>
        Served by: <code>{instance ?? "…"}</code>
      </footer>
    </div>
  );
}
