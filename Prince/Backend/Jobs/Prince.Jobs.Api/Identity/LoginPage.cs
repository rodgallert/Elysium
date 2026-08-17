using System.Net;

namespace Prince.Jobs.Api.Identity;

public static class LoginPage
{
    private const string Template = """
                                     <!doctype html>
                                     <html>
                                     <head>
                                         <title>Prince.Jobs — Admin login</title>
                                         <style>
                                             body { font-family: sans-serif; max-width: 320px; margin: 4rem auto; }
                                             input { display: block; width: 100%; margin-bottom: 0.75rem; padding: 0.5rem; box-sizing: border-box; }
                                             button { padding: 0.5rem 1rem; }
                                         </style>
                                     </head>
                                     <body>
                                         <h2>Prince.Jobs — Admin login</h2>
                                         __ERROR__
                                         <form method="post" action="/admin/login">
                                             <input type="hidden" name="returnUrl" value="__RETURN_URL__" />
                                             <input type="email" name="email" placeholder="Email" required />
                                             <input type="password" name="password" placeholder="Password" required />
                                             <button type="submit">Sign in</button>
                                         </form>
                                     </body>
                                     </html>
                                     """;

    public static string Render(string returnUrl, bool failed)
    {
        var error = failed ? "<p style=\"color:#c0392b\">Invalid email or password.</p>" : "";
        var encodedReturnUrl = WebUtility.HtmlEncode(returnUrl);

        return Template
            .Replace("__ERROR__", error)
            .Replace("__RETURN_URL__", encodedReturnUrl);
    }
}
