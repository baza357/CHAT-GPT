import { AuthForm } from "@/components/auth/AuthForm";

type LoginPageProps = {
  searchParams: Promise<{ error?: string }>;
};

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error } = await searchParams;
  return (
    <AuthForm
      mode="login"
      initialError={error ? "Ссылка недействительна или устарела." : ""}
    />
  );
}
