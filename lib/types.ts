export type UserProfile = {
  id: string;
  contact_number: number;
  username: string;
  display_name: string;
  avatar_url: string | null;
  bio: string | null;
  status: string;
  last_seen: string | null;
  created_at: string;
  updated_at: string;
};

export type Message = {
  id: number;
  chat_id: string;
  sender_id: string;
  body: string;
  created_at: string;
};
