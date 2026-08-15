import { redirect } from "next/navigation";
import { DirectoryLayout } from "@/components/directory/DirectoryLayout";
import { createClient } from "@/lib/supabase/server";

export default async function CallsPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) redirect("/login");
  return <DirectoryLayout mode="calls" user={{ id: data.user.id, email: data.user.email ?? "" }} />;
}
