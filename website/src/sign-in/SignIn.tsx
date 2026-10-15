import { LockIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"

// OpenTraffic's sign-in page for password-protected shares, served by the app's proxy (see
// Sources/OpenTrafficCore/ShareAccess.swift). It's rendered once to static HTML by
// scripts/build-sign-in.mjs; the app fills in the __OT_…__ values and the slots. No script runs.

/** Where the app puts a part that depends on the request. */
function Slot({ name }: { name: string }) {
  return <template data-ot-slot={name} />
}

/** OpenTraffic's mark: a local server, through the tunnel, out to two people. */
function Mark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 56 32" fill="currentColor" aria-hidden="true" className={className}>
      <circle cx="4" cy="18.5" r="3" />
      <rect x="6" y="17.6" width="10" height="1.8" />
      <path d="M14 30V15.5a11.5 11.5 0 0 1 23 0V30h-4.6V15.5a6.9 6.9 0 0 0-13.8 0V30z" />
      <path d="M18 16.4h21c4 0 5-6.4 9-6.4" fill="none" stroke="currentColor" strokeWidth="1.8" />
      <path d="M18 20.6h21c4 0 5 4.4 9 4.4" fill="none" stroke="currentColor" strokeWidth="1.8" />
      <circle cx="51.4" cy="10" r="3.6" />
      <circle cx="51.4" cy="25" r="3.6" />
    </svg>
  )
}

export function SignInPage() {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted p-6 md:p-10">
      <div className="flex w-full max-w-sm flex-col gap-6">
        <div className="flex items-center gap-2 self-center font-medium">
          <div className="flex size-7 items-center justify-center rounded-md bg-primary text-primary-foreground">
            <Mark className="w-5" />
          </div>
          OpenTraffic
        </div>
        <Card>
          <CardHeader className="text-center">
            <CardTitle className="text-xl">__OT_SHARE_NAME__</CardTitle>
            <CardDescription className="flex items-center justify-center gap-1.5">
              <LockIcon className="size-3.5" />
              Password protected
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form method="post" action="/__opentraffic/sign-in">
              <input type="hidden" name="next" value="__OT_NEXT__" />
              <FieldGroup>
                <Slot name="password" />
                <Slot name="name" />
                <Field>
                  <Button type="submit">Continue</Button>
                </Field>
              </FieldGroup>
            </form>
          </CardContent>
        </Card>
        <FieldDescription className="px-6 text-center">
          Ask whoever sent you this link for the password.
        </FieldDescription>
      </div>
    </div>
  )
}

export function PasswordField({ invalid }: { invalid: boolean }) {
  return (
    <Field data-invalid={invalid || undefined}>
      <FieldLabel htmlFor="password">Password</FieldLabel>
      <Input
        id="password"
        name="password"
        type="password"
        autoComplete="current-password"
        autoFocus
        required
        aria-invalid={invalid || undefined}
      />
      {invalid && <FieldError>__OT_ERROR__</FieldError>}
    </Field>
  )
}

/** Only on shares with live collaboration, where people are shown by name. */
export function NameField() {
  return (
    <Field>
      <FieldLabel htmlFor="name">Your name</FieldLabel>
      <Input id="name" name="name" type="text" autoComplete="nickname" maxLength={32} placeholder="Optional" />
      <FieldDescription>Shown to others here.</FieldDescription>
    </Field>
  )
}
