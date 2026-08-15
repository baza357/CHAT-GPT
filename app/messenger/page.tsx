import { redirect } from "next/navigation";
import { MessengerLayout } from "@/components/messenger/MessengerLayout";
import { MessageDeletionController } from "@/components/messenger/MessageDeletionController";
import { createClient } from "@/lib/supabase/server";

export default async function MessengerPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();

  if (error || !data.user) redirect("/login");

  return (
    <>
      <MessengerLayout
        user={{ id: data.user.id, email: data.user.email ?? "" }}
      />
      <MessageDeletionController userId={data.user.id} />
    </>
  );
}
