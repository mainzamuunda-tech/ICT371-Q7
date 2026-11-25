# Question 7: Water Meter Readings and Billing

PostgreSQL. Run `solution.sql` from top to bottom. It creates its own schema `q7`.
Scheduled jobs use pg_cron.

## Index
`bills(due_on) WHERE amount_paid < charge`

Overdue searches compare due_on to today and only care about unpaid bills. A partial index on due_on restricted to unpaid bills is small and supports the date comparison directly.
