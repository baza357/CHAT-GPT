import { redirect } from "next/navigation";
import { CalendarLayout } from "@/components/calendar/CalendarLayout";
import { createClient } from "@/lib/supabase/server";

export default async function CalendarPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) redirect("/login");
  return <CalendarLayout user={{ id: data.user.id, email: data.user.email ?? "" }} />;
}
