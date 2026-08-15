import { redirect } from "next/navigation";
import { WorkpieceDefectLayout } from "@/components/products/WorkpieceDefectLayout";
import { createClient } from "@/lib/supabase/server";

export default async function WorkpieceDefectsPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) redirect("/login");

  return <WorkpieceDefectLayout user={{ id: data.user.id, email: data.user.email ?? "" }} />;
}
