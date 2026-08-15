import { redirect } from "next/navigation";
import { ProductAccountingLayout } from "@/components/products/ProductAccountingLayout";
import { createClient } from "@/lib/supabase/server";

export default async function ProductsPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) redirect("/login");

  return <ProductAccountingLayout user={{ id: data.user.id, email: data.user.email ?? "" }} />;
}
