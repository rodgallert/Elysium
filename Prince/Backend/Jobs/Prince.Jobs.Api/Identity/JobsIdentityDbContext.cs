using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace Prince.Jobs.Api.Identity;

public class JobsIdentityDbContext(DbContextOptions<JobsIdentityDbContext> options)
    : IdentityDbContext<IdentityUser>(options);
