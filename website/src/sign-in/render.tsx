import { renderToStaticMarkup } from "react-dom/server"
import css from "./sign-in.css?inline"
import { NameField, PasswordField, SignInPage } from "./SignIn"

export const styles = css
export const page = renderToStaticMarkup(<SignInPage />)
export const passwordField = renderToStaticMarkup(<PasswordField invalid={false} />)
export const passwordFieldInvalid = renderToStaticMarkup(<PasswordField invalid />)
export const nameField = renderToStaticMarkup(<NameField />)
