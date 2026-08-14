import { redirect } from "next/navigation";
import { ProfileSettings } from "@/components/settings/ProfileSettings";
import { createClient } from "@/lib/supabase/server";

export default async function SettingsPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();

  if (error || !data.user) redirect("/login");
  return <ProfileSettings userId={data.user.id} />;
}
