mod common;

use axum::{
    body::Body,
    http::{Request, StatusCode, header},
};
use common::{PUBLIC_URL, TestApp, error_code, read};
use habitd::util::now;
use serde_json::{Value, json};
use uuid::Uuid;

// 2025-06-02 is a Monday; the dates below are safely in the past.
const MON: &str = "2025-06-02";
const TUE: &str = "2025-06-03";
const WED: &str = "2025-06-04";
const SUN: &str = "2025-06-08";
const NEXT_MON: &str = "2025-06-09";

fn boolean(schedule: &str) -> Value {
    json!({ "name": "Habit", "kind": "boolean", "schedule": schedule })
}

async fn today(app: &TestApp, token: &str, date: &str) -> Value {
    let (status, body) = app.get(token, &format!("/api/v1/today?date={date}")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

#[tokio::test]
async fn meta_needs_no_credential() {
    let app = TestApp::new().await;
    let request = Request::get("/api/v1/meta").body(Body::empty()).unwrap();
    let (status, body) = read(app.send(request).await).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({ "name": "habitd", "version": "0.1.0", "api_version": 1 }));
}

#[tokio::test]
async fn everything_else_needs_a_credential() {
    let app = TestApp::new().await;
    for path in ["/api/v1/me", "/api/v1/habits", "/api/v1/today", "/api/v1/tokens"] {
        let request = Request::get(path).body(Body::empty()).unwrap();
        let (status, body) = read(app.send(request).await).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{path}");
        assert_eq!(error_code(&body), "unauthenticated");
    }
    let (status, _) = app.get("hbt_not-a-real-token", "/api/v1/me").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn unknown_api_paths_are_json_404s() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let (status, body) = app.get(&token, "/api/v1/nope").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error_code(&body), "not_found");
}

#[tokio::test]
async fn me_can_be_read_and_updated() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;

    let (_, me) = app.get(&token, "/api/v1/me").await;
    assert_eq!(me["username"], "alice");
    assert_eq!(me["timezone"], "UTC");
    assert_eq!(me["week_start"], 1);

    let patch = json!({ "timezone": "America/Bogota", "week_start": 7 });
    let (status, me) = app.api(&token, "PATCH", "/api/v1/me", patch).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["timezone"], "America/Bogota");
    assert_eq!(me["week_start"], 7);

    for bad in [
        json!({ "timezone": "Mars/Olympus" }),
        json!({ "week_start": 0 }),
        json!({ "week_start": 8 }),
    ] {
        let (status, body) = app.api(&token, "PATCH", "/api/v1/me", bad).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error_code(&body), "validation_failed");
    }
}

#[tokio::test]
async fn habit_crud() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;

    let body = json!({
        "name": "Drink water", "kind": "counter", "schedule": "weekdays",
        "weekdays": [5, 1, 3], "goal": 8,
    });
    let (status, habit) = app.api(&token, "POST", "/api/v1/habits", body).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(habit["weekdays"], json!([1, 3, 5]));
    assert_eq!(habit["goal"], 8);
    assert_eq!(habit["position"], 0);
    assert_eq!(habit["archived"], false);
    assert_eq!(habit["webhook_url"], Value::Null);
    assert_eq!(habit["description"], "");
    assert!(habit["created_at"].as_str().unwrap().ends_with('Z'));
    let id = habit["id"].as_str().unwrap();

    let second = app.habit(&token, boolean("daily")).await;
    let (_, fetched) = app.get(&token, &format!("/api/v1/habits/{second}")).await;
    assert_eq!(fetched["position"], 1);
    assert_eq!(fetched["weekdays"], Value::Null);
    assert_eq!(fetched["goal"], 1);

    let (status, patched) = app
        .api(
            &token,
            "PATCH",
            &format!("/api/v1/habits/{id}"),
            json!({ "name": "Water", "schedule": "weekly", "goal": 40 }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{patched}");
    assert_eq!(patched["name"], "Water");
    assert_eq!(patched["schedule"], "weekly");
    assert_eq!(patched["weekdays"], Value::Null);
    assert_eq!(patched["kind"], "counter");

    let (_, list) = app.get(&token, "/api/v1/habits").await;
    assert_eq!(list.as_array().unwrap().len(), 2);

    let (status, _) = app.api(&token, "DELETE", &format!("/api/v1/habits/{id}"), Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = app.get(&token, &format!("/api/v1/habits/{id}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn client_supplied_ids_conflict_when_reused() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let id = Uuid::now_v7().to_string();
    let mut body = boolean("daily");
    body["id"] = json!(id);

    assert_eq!(app.habit(&token, body.clone()).await, id);
    let (status, error) = app.api(&token, "POST", "/api/v1/habits", body).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&error), "conflict");
}

#[tokio::test]
async fn habit_validation() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let invalid = [
        json!({ "name": "", "kind": "boolean", "schedule": "daily" }),
        json!({ "name": "x".repeat(101), "kind": "boolean", "schedule": "daily" }),
        json!({ "name": "A", "kind": "timer", "schedule": "daily" }),
        json!({ "name": "A", "kind": "boolean", "schedule": "monthly" }),
        json!({ "name": "A", "kind": "boolean", "schedule": "weekdays" }),
        json!({ "name": "A", "kind": "boolean", "schedule": "weekdays", "weekdays": [] }),
        json!({ "name": "A", "kind": "boolean", "schedule": "weekdays", "weekdays": [8] }),
        json!({ "name": "A", "kind": "boolean", "schedule": "daily", "weekdays": [1] }),
        json!({ "name": "A", "kind": "boolean", "schedule": "daily", "goal": 2 }),
        json!({ "name": "A", "kind": "boolean", "schedule": "weekly", "goal": 8 }),
        json!({ "name": "A", "kind": "counter", "schedule": "daily", "goal": 0 }),
        json!({ "kind": "counter", "schedule": "daily" }),
    ];
    for body in invalid {
        let (status, error) = app.api(&token, "POST", "/api/v1/habits", body.clone()).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
        assert_eq!(error_code(&error), "validation_failed");
    }

    // A patch must leave the habit satisfying the goal rules.
    let weekly = app
        .habit(&token, json!({ "name": "Gym", "kind": "boolean", "schedule": "weekly", "goal": 3 }))
        .await;
    let path = format!("/api/v1/habits/{weekly}");
    let (status, _) = app.api(&token, "PATCH", &path, json!({ "schedule": "daily" })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = app.api(&token, "PATCH", &path, json!({ "schedule": "weekdays" })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, habit) =
        app.api(&token, "PATCH", &path, json!({ "schedule": "daily", "goal": 1 })).await;
    assert_eq!(status, StatusCode::OK, "{habit}");

    // Malformed JSON is a bad request, not a validation failure.
    let request = Request::post("/api/v1/habits")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from("{"))
        .unwrap();
    let (status, error) = read(app.send(request).await).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&error), "bad_request");
}

#[tokio::test]
async fn ordering_and_archiving() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let a = app.habit(&token, boolean("daily")).await;
    let b = app.habit(&token, boolean("daily")).await;
    let c = app.habit(&token, boolean("daily")).await;

    let ids = |list: &Value| -> Vec<String> {
        list.as_array().unwrap().iter().map(|h| h["id"].as_str().unwrap().to_string()).collect()
    };

    let (status, _) =
        app.api(&token, "PUT", "/api/v1/habits/order", json!({ "ids": [c, a, b] })).await;
    assert_eq!(status, StatusCode::OK);
    let (_, list) = app.get(&token, "/api/v1/habits").await;
    assert_eq!(ids(&list), vec![c.clone(), a.clone(), b.clone()]);

    // Missing, duplicated or foreign IDs are rejected.
    for bad in [json!([c, a]), json!([c, a, a]), json!([c, a, b, Uuid::now_v7()])] {
        let (status, _) =
            app.api(&token, "PUT", "/api/v1/habits/order", json!({ "ids": bad })).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }

    let path = format!("/api/v1/habits/{c}");
    let (_, archived) = app.api(&token, "PATCH", &path, json!({ "archived": true })).await;
    assert_eq!(archived["archived"], true);
    let (_, list) = app.get(&token, "/api/v1/habits").await;
    assert_eq!(ids(&list), vec![a.clone(), b.clone()]);
    let (_, list) = app.get(&token, "/api/v1/habits?archived=true").await;
    assert_eq!(ids(&list), vec![c.clone()]);
    let (_, list) = app.get(&token, "/api/v1/habits?archived=all").await;
    assert_eq!(list.as_array().unwrap().len(), 3);
    assert!(
        today(&app, &token, MON).await["habits"]
            .as_array()
            .unwrap()
            .iter()
            .all(|h| h["id"] != json!(c))
    );

    // The order now only covers the two active habits; a restored habit goes last.
    let (status, _) =
        app.api(&token, "PUT", "/api/v1/habits/order", json!({ "ids": [b, a] })).await;
    assert_eq!(status, StatusCode::OK);
    app.api(&token, "PATCH", &path, json!({ "archived": false })).await;
    let (_, list) = app.get(&token, "/api/v1/habits").await;
    assert_eq!(ids(&list), vec![b, a, c]);
}

#[tokio::test]
async fn completion_boolean_daily() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;

    let status = app.set(&token, &habit, MON, 1).await;
    assert_eq!(
        status,
        json!({
            "habit_id": habit, "date": MON, "value": 1, "period_value": 1, "done": true,
            "skipped": false, "note": "", "streak": 1, "best_streak": 1,
        })
    );
    // Completion is per day.
    assert_eq!(today(&app, &token, TUE).await["habits"][0]["done"], false);
    let status = app.set(&token, &habit, MON, 0).await;
    assert_eq!(status["done"], false);
}

#[tokio::test]
async fn completion_counter_daily() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 3 }),
        )
        .await;

    assert_eq!(app.increment(&token, &habit, MON, 2).await["done"], false);
    let status = app.increment(&token, &habit, MON, 1).await;
    assert_eq!((status["value"].clone(), status["done"].clone()), (json!(3), json!(true)));
    // Counters keep counting past the goal.
    let status = app.increment(&token, &habit, MON, 1).await;
    assert_eq!((status["value"].clone(), status["done"].clone()), (json!(4), json!(true)));
    assert_eq!(today(&app, &token, TUE).await["habits"][0]["period_value"], 0);
}

#[tokio::test]
async fn completion_boolean_weekdays() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let mut body = boolean("weekdays");
    body["weekdays"] = json!([1, 3]);
    let habit = app.habit(&token, body).await;

    assert_eq!(today(&app, &token, MON).await["habits"][0]["due"], true);
    assert_eq!(today(&app, &token, WED).await["habits"][0]["due"], true);
    let tuesday = today(&app, &token, TUE).await;
    assert_eq!(tuesday["habits"][0]["due"], false);

    // It can still be logged on a day it is not due.
    let status = app.set(&token, &habit, TUE, 1).await;
    assert_eq!(status["done"], true);
    let tuesday = today(&app, &token, TUE).await;
    assert_eq!(
        (tuesday["habits"][0]["due"].clone(), tuesday["habits"][0]["value"].clone()),
        (json!(false), json!(1))
    );
    assert_eq!(today(&app, &token, MON).await["habits"][0]["done"], false);
}

#[tokio::test]
async fn completion_counter_weekdays() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(&token, json!({ "name": "Pages", "kind": "counter", "schedule": "weekdays", "weekdays": [1], "goal": 10 }))
        .await;

    assert_eq!(app.increment(&token, &habit, MON, 9).await["done"], false);
    let status = app.increment(&token, &habit, MON, 1).await;
    assert_eq!((status["period_value"].clone(), status["done"].clone()), (json!(10), json!(true)));
}

#[tokio::test]
async fn completion_boolean_weekly() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(&token, json!({ "name": "Gym", "kind": "boolean", "schedule": "weekly", "goal": 3 }))
        .await;

    assert_eq!(app.set(&token, &habit, MON, 1).await["period_value"], 1);
    let status = app.set(&token, &habit, WED, 1).await;
    assert_eq!(
        (status["value"].clone(), status["period_value"].clone(), status["done"].clone()),
        (json!(1), json!(2), json!(false))
    );
    // Setting a day that is already checked changes nothing.
    assert_eq!(app.set(&token, &habit, WED, 1).await["period_value"], 2);
    let status = app.set(&token, &habit, SUN, 1).await;
    assert_eq!((status["period_value"].clone(), status["done"].clone()), (json!(3), json!(true)));

    // The whole week sees the same total; an unchecked day still shows value 0.
    let tuesday = today(&app, &token, TUE).await;
    let row = &tuesday["habits"][0];
    assert_eq!(
        (
            row["due"].clone(),
            row["value"].clone(),
            row["period_value"].clone(),
            row["done"].clone()
        ),
        (json!(true), json!(0), json!(3), json!(true))
    );
    assert_eq!(tuesday["week_start_date"], MON);

    // The next week starts from nothing.
    let next = today(&app, &token, NEXT_MON).await;
    assert_eq!(
        (next["habits"][0]["period_value"].clone(), next["habits"][0]["done"].clone()),
        (json!(0), json!(false))
    );

    // Unchecking one day takes the week below its goal again.
    assert_eq!(app.set(&token, &habit, MON, 0).await["done"], false);
}

#[tokio::test]
async fn completion_counter_weekly() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(&token, json!({ "name": "Km", "kind": "counter", "schedule": "weekly", "goal": 20 }))
        .await;

    app.increment(&token, &habit, MON, 8).await;
    let status = app.increment(&token, &habit, WED, 7).await;
    assert_eq!(
        (status["value"].clone(), status["period_value"].clone(), status["done"].clone()),
        (json!(7), json!(15), json!(false))
    );
    let status = app.increment(&token, &habit, SUN, 5).await;
    assert_eq!((status["period_value"].clone(), status["done"].clone()), (json!(20), json!(true)));

    // Set changes one day, never the week's total directly.
    let status = app.set(&token, &habit, WED, 1).await;
    assert_eq!(
        (status["value"].clone(), status["period_value"].clone(), status["done"].clone()),
        (json!(1), json!(14), json!(false))
    );
}

#[tokio::test]
async fn changing_the_goal_re_evaluates_the_past() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 8 }),
        )
        .await;
    app.increment(&token, &habit, MON, 5).await;
    assert_eq!(today(&app, &token, MON).await["habits"][0]["done"], false);

    app.api(&token, "PATCH", &format!("/api/v1/habits/{habit}"), json!({ "goal": 5 })).await;
    let row = today(&app, &token, MON).await["habits"][0].clone();
    assert_eq!((row["value"].clone(), row["done"].clone()), (json!(5), json!(true)));
}

#[tokio::test]
async fn week_boundaries_for_each_week_start() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(&token, json!({ "name": "Km", "kind": "counter", "schedule": "weekly", "goal": 2 }))
        .await;
    // One unit on each day from Monday 2025-06-02 to Tuesday 2025-06-17.
    for day in 2..=17 {
        app.increment(&token, &habit, &format!("2025-06-{day:02}"), 1).await;
    }

    // Viewed from Wednesday 2025-06-11, the week containing it starts on:
    let expected = [
        (1, "2025-06-09"),
        (2, "2025-06-10"),
        (3, "2025-06-11"),
        (4, "2025-06-05"),
        (5, "2025-06-06"),
        (6, "2025-06-07"),
        (7, "2025-06-08"),
    ];
    for (week_start, start) in expected {
        app.api(&token, "PATCH", "/api/v1/me", json!({ "week_start": week_start })).await;
        let view = today(&app, &token, "2025-06-11").await;
        assert_eq!(view["week_start_date"], start, "week_start {week_start}");
        assert_eq!(view["habits"][0]["period_value"], 7, "week_start {week_start}");
    }

    // With Sunday weeks, Saturday 06-07 and Sunday 06-08 fall in different weeks:
    // the first only has Monday..Saturday logged, the second all seven days.
    app.api(&token, "PATCH", "/api/v1/me", json!({ "week_start": 7 })).await;
    assert_eq!(today(&app, &token, "2025-06-07").await["habits"][0]["period_value"], 6);
    assert_eq!(today(&app, &token, "2025-06-08").await["habits"][0]["period_value"], 7);
    // A write reports the week the same way.
    let status = app.set(&token, &habit, "2025-06-07", 0).await;
    assert_eq!(status["period_value"], 5);
}

#[tokio::test]
async fn increments_are_idempotent_per_op_id() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 8 }),
        )
        .await;
    let path = format!("/api/v1/habits/{habit}/entries/{MON}/increment");
    let op = json!({ "op_id": Uuid::now_v7(), "delta": 2 });

    for _ in 0..3 {
        let (status, body) = app.api(&token, "POST", &path, op.clone()).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["value"], 2);
    }
    // A different op adds up; delta defaults to 1.
    let (_, body) = app.api(&token, "POST", &path, json!({ "op_id": Uuid::now_v7() })).await;
    assert_eq!(body["value"], 3);

    for bad in [
        json!({ "op_id": Uuid::now_v7(), "delta": 0 }),
        json!({ "op_id": Uuid::now_v7(), "delta": 1001 }),
        json!({ "delta": 1 }),
        json!({ "op_id": "nope", "delta": 1 }),
    ] {
        let (status, _) = app.api(&token, "POST", &path, bad).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }
}

#[tokio::test]
async fn values_are_clamped() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let counter = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 8 }),
        )
        .await;
    let flag = app.habit(&token, boolean("daily")).await;

    // Counters stay within 0..=1_000_000.
    assert_eq!(app.increment(&token, &counter, MON, -5).await["value"], 0);
    assert_eq!(app.increment(&token, &counter, MON, 3).await["value"], 3);
    assert_eq!(app.increment(&token, &counter, MON, -10).await["value"], 0);
    assert_eq!(app.set(&token, &counter, MON, 5_000_000).await["value"], 1_000_000);
    assert_eq!(app.increment(&token, &counter, MON, 1000).await["value"], 1_000_000);

    // Booleans stay within 0..=1.
    assert_eq!(app.set(&token, &flag, MON, 7).await["value"], 1);
    assert_eq!(app.increment(&token, &flag, MON, 1).await["value"], 1);
    assert_eq!(app.increment(&token, &flag, MON, -1).await["value"], 0);
    assert_eq!(app.increment(&token, &flag, MON, -1).await["value"], 0);

    let path = format!("/api/v1/habits/{counter}/entries/{MON}");
    let (status, _) = app.api(&token, "PUT", &path, json!({ "value": -1 })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn write_dates_must_be_real_and_not_in_the_future() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;

    for date in ["2025-02-30", "2025-6-2", "yesterday", "2999-01-01"] {
        let path = format!("/api/v1/habits/{habit}/entries/{date}");
        let (status, body) = app.api(&token, "PUT", &path, json!({ "value": 1 })).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{date}");
        assert_eq!(error_code(&body), "validation_failed");
    }
    let tomorrow = (chrono::Utc::now().date_naive() + chrono::Days::new(1)).to_string();
    assert_eq!(app.set(&token, &habit, &tomorrow, 1).await["value"], 1);
}

#[tokio::test]
async fn entries_listing() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let a = app.habit(&token, boolean("daily")).await;
    let b = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 8 }),
        )
        .await;
    app.set(&token, &a, MON, 1).await;
    app.increment(&token, &b, MON, 4).await;
    app.increment(&token, &b, WED, 2).await;
    app.increment(&token, &b, NEXT_MON, 9).await;

    let (status, all) = app.get(&token, &format!("/api/v1/entries?from={MON}&to={SUN}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        all,
        json!([
            { "habit_id": a, "date": MON, "value": 1, "skipped": false, "note": "" },
            { "habit_id": b, "date": MON, "value": 4, "skipped": false, "note": "" },
            { "habit_id": b, "date": WED, "value": 2, "skipped": false, "note": "" },
        ])
    );
    let (_, only_a) =
        app.get(&token, &format!("/api/v1/entries?from={MON}&to={NEXT_MON}&habit_id={a}")).await;
    assert_eq!(only_a.as_array().unwrap().len(), 1);

    let (status, _) = app.get(&token, "/api/v1/entries?from=2025-01-01&to=2026-01-01").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = app.get(&token, "/api/v1/entries?from=2025-01-01&to=2026-01-02").await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = app.get(&token, &format!("/api/v1/entries?from={SUN}&to={MON}")).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = app.get(&token, &format!("/api/v1/entries?from={MON}")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn today_defaults_to_the_users_time_zone() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    app.api(&token, "PATCH", "/api/v1/me", json!({ "timezone": "Pacific/Kiritimati" })).await;
    let (_, view) = app.get(&token, "/api/v1/today").await;
    let expected = chrono::Utc::now().with_timezone(&chrono_tz::Pacific::Kiritimati).date_naive();
    assert_eq!(view["date"], expected.to_string());
}

#[tokio::test]
async fn other_users_ids_are_not_found() {
    let app = TestApp::new().await;
    let alice = app.user("alice").await;
    let bob = app.user("bob").await;
    let habit = app.habit(&alice, boolean("daily")).await;
    app.set(&alice, &habit, MON, 1).await;
    let (_, tokens) = app.get(&alice, "/api/v1/tokens").await;
    let alice_token_id = tokens[0]["id"].as_str().unwrap().to_string();

    let attempts = [
        ("GET", format!("/api/v1/habits/{habit}"), Value::Null),
        ("PATCH", format!("/api/v1/habits/{habit}"), json!({ "name": "Mine now" })),
        ("DELETE", format!("/api/v1/habits/{habit}"), Value::Null),
        ("POST", format!("/api/v1/habits/{habit}/webhook"), Value::Null),
        ("DELETE", format!("/api/v1/habits/{habit}/webhook"), Value::Null),
        ("PUT", format!("/api/v1/habits/{habit}/entries/{MON}"), json!({ "value": 0 })),
        (
            "POST",
            format!("/api/v1/habits/{habit}/entries/{MON}/increment"),
            json!({ "op_id": Uuid::now_v7(), "delta": 1 }),
        ),
        ("GET", format!("/api/v1/entries?from={MON}&to={MON}&habit_id={habit}"), Value::Null),
        ("DELETE", format!("/api/v1/tokens/{alice_token_id}"), Value::Null),
        ("GET", "/api/v1/habits/not-a-uuid".to_string(), Value::Null),
    ];
    for (method, path, body) in attempts {
        let (status, error) = app.api(&bob, method, &path, body).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{method} {path}");
        assert_eq!(error_code(&error), "not_found");
    }

    // Bob sees none of Alice's data, and hers is untouched.
    assert_eq!(app.get(&bob, "/api/v1/habits").await.1, json!([]));
    assert_eq!(app.get(&bob, &format!("/api/v1/entries?from={MON}&to={MON}")).await.1, json!([]));
    assert_eq!(today(&app, &bob, MON).await["habits"], json!([]));
    assert_eq!(today(&app, &alice, MON).await["habits"][0]["value"], 1);

    // Bob cannot reorder with Alice's habit either.
    let (status, _) = app.api(&bob, "PUT", "/api/v1/habits/order", json!({ "ids": [habit] })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn deleting_a_habit_deletes_its_entries() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;
    app.set(&token, &habit, MON, 1).await;
    app.increment(&token, &habit, TUE, 1).await;

    app.api(&token, "DELETE", &format!("/api/v1/habits/{habit}"), Value::Null).await;
    for table in ["entries", "applied_ops"] {
        let count: i64 =
            sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT COUNT(*) FROM {table}")))
                .fetch_one(&app.state.db)
                .await
                .unwrap();
        assert_eq!(count, 0, "{table}");
    }
}

#[tokio::test]
async fn api_tokens_can_be_created_listed_and_revoked() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;

    let (status, created) = app
        .api(&token, "POST", "/api/v1/tokens", json!({ "name": "script", "expires_in_days": 7 }))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let secret = created["token"].as_str().unwrap().to_string();
    assert!(secret.starts_with("hbt_") && secret.len() == 47);
    assert_eq!(created["kind"], "api");
    assert!(created["expires_at"].is_string());

    // The new token works, and the list never includes secrets.
    let (status, list) = app.get(&secret, "/api/v1/tokens").await;
    assert_eq!(status, StatusCode::OK);
    let list = list.as_array().unwrap();
    assert_eq!(list.len(), 2);
    assert!(list.iter().all(|t| t.get("token").is_none() && t.get("token_hash").is_none()));
    assert_eq!(list.iter().filter(|t| t["current"] == true).count(), 1);
    assert_eq!(list.iter().find(|t| t["current"] == true).unwrap()["name"], "script");
    // Only the hash is stored.
    let stored: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM tokens WHERE CAST(token_hash AS TEXT) LIKE 'hbt_%'",
    )
    .fetch_one(&app.state.db)
    .await
    .unwrap();
    assert_eq!(stored, 0);

    let id = created["id"].as_str().unwrap();
    let (status, _) = app.api(&token, "DELETE", &format!("/api/v1/tokens/{id}"), Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = app.get(&secret, "/api/v1/me").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    for bad in [json!({ "name": "" }), json!({ "name": "x", "expires_in_days": 0 })] {
        let (status, _) = app.api(&token, "POST", "/api/v1/tokens", bad).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }
}

#[tokio::test]
async fn expired_tokens_stop_working_and_are_cleaned_up() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    assert_eq!(app.get(&token, "/api/v1/me").await.0, StatusCode::OK);

    sqlx::query("UPDATE tokens SET expires_at = ?")
        .bind(now() - 1)
        .execute(&app.state.db)
        .await
        .unwrap();
    assert_eq!(app.get(&token, "/api/v1/me").await.0, StatusCode::UNAUTHORIZED);

    habitd::db::cleanup(&app.state.db).await.unwrap();
    let left: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM tokens").fetch_one(&app.state.db).await.unwrap();
    assert_eq!(left, 0);
}

#[tokio::test]
async fn sessions_are_extended_on_use_at_most_once_a_minute() {
    let app = TestApp::new().await;
    let session = app.session("alice").await;
    let request = || {
        Request::get("/api/v1/me")
            .header(header::COOKIE, format!("other=1; habitd_session={session}"))
            .body(Body::empty())
            .unwrap()
    };
    let expiry = || async {
        sqlx::query_as::<_, (Option<i64>, Option<i64>)>(
            "SELECT last_used_at, expires_at FROM tokens",
        )
        .fetch_one(&app.state.db)
        .await
        .unwrap()
    };

    assert_eq!(app.send(request()).await.status(), StatusCode::OK);
    let (used, expires) = expiry().await;
    assert!(used.is_some());
    assert!(expires.unwrap() >= now() + 30 * 24 * 3600 - 5);

    // A second request within the minute does not write again.
    sqlx::query("UPDATE tokens SET expires_at = 4000000000").execute(&app.state.db).await.unwrap();
    assert_eq!(app.send(request()).await.status(), StatusCode::OK);
    assert_eq!(expiry().await.1, Some(4000000000));

    // After a minute it does.
    sqlx::query("UPDATE tokens SET last_used_at = ?")
        .bind(now() - 61)
        .execute(&app.state.db)
        .await
        .unwrap();
    assert_eq!(app.send(request()).await.status(), StatusCode::OK);
    assert!(expiry().await.1.unwrap() < 4000000000);
}

#[tokio::test]
async fn cookie_requests_that_mutate_need_a_matching_origin() {
    let app = TestApp::new().await;
    let session = app.session("alice").await;
    let post = |origin: Option<&str>| {
        let mut request = Request::post("/api/v1/habits")
            .header(header::COOKIE, format!("habitd_session={session}"))
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(origin) = origin {
            request = request.header(header::ORIGIN, origin);
        }
        request.body(Body::from(boolean("daily").to_string())).unwrap()
    };

    for origin in [None, Some("https://evil.test"), Some("http://habits.test"), Some("null")] {
        let (status, body) = read(app.send(post(origin)).await).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{origin:?}");
        assert_eq!(error_code(&body), "forbidden");
    }
    let response = app.send(post(Some(PUBLIC_URL))).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    assert!(response.headers().get(header::ACCESS_CONTROL_ALLOW_ORIGIN).is_none());

    // Reads need no Origin, and bearer tokens are exempt.
    let get = Request::get("/api/v1/habits")
        .header(header::COOKIE, format!("habitd_session={session}"))
        .body(Body::empty())
        .unwrap();
    assert_eq!(app.send(get).await.status(), StatusCode::OK);
    let token = app.user("alice").await;
    app.habit(&token, boolean("daily")).await;

    // A device or API token is not accepted as a cookie.
    let as_cookie = Request::get("/api/v1/me")
        .header(header::COOKIE, format!("habitd_session={token}"))
        .body(Body::empty())
        .unwrap();
    assert_eq!(app.send(as_cookie).await.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn logout_deletes_the_credential_that_made_the_request() {
    let app = TestApp::new().await;
    let session = app.session("alice").await;
    let other = app.user("alice").await;

    let request = Request::post("/auth/logout")
        .header(header::COOKIE, format!("habitd_session={session}"))
        .header(header::ORIGIN, PUBLIC_URL)
        .body(Body::empty())
        .unwrap();
    let response = app.send(request).await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(response.headers()[header::SET_COOKIE].to_str().unwrap().contains("Max-Age=0"));

    let request = Request::get("/api/v1/me")
        .header(header::COOKIE, format!("habitd_session={session}"))
        .body(Body::empty())
        .unwrap();
    assert_eq!(app.send(request).await.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(app.get(&other, "/api/v1/me").await.0, StatusCode::OK);
}

async fn hook(app: &TestApp, method: &str, url: &str) -> (StatusCode, Value) {
    let path = url.strip_prefix(PUBLIC_URL).unwrap();
    let request = Request::builder().method(method).uri(path).body(Body::empty()).unwrap();
    let response = app.send(request).await;
    if response.status() == StatusCode::METHOD_NOT_ALLOWED {
        return (response.status(), Value::Null);
    }
    read(response).await
}

async fn webhook_url(app: &TestApp, token: &str, habit: &str) -> String {
    let (status, body) =
        app.api(token, "POST", &format!("/api/v1/habits/{habit}/webhook"), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    body["webhook_url"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn webhook_on_a_counter_adds_delta() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(
            &token,
            json!({ "name": "Water", "kind": "counter", "schedule": "daily", "goal": 3 }),
        )
        .await;
    let url = webhook_url(&app, &token, &habit).await;
    assert!(url.starts_with("https://habits.test/hook/"));
    assert_eq!(
        app.get(&token, &format!("/api/v1/habits/{habit}")).await.1["webhook_url"],
        json!(url)
    );

    let (status, body) = hook(&app, "POST", &url).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!((body["value"].clone(), body["done"].clone()), (json!(1), json!(false)));
    let (_, body) = hook(&app, "POST", &format!("{url}?delta=2")).await;
    assert_eq!((body["value"].clone(), body["done"].clone()), (json!(3), json!(true)));
    let (_, body) = hook(&app, "POST", &format!("{url}?delta=-1")).await;
    assert_eq!(body["value"], 2);
    assert_eq!(body["habit_id"], json!(habit));

    // It logged against today in the owner's time zone.
    let (_, view) = app.get(&token, "/api/v1/today").await;
    assert_eq!(view["date"], body["date"]);
    assert_eq!(view["habits"][0]["value"], 2);

    let (status, _) = hook(&app, "POST", &format!("{url}?delta=0")).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    // Only POST triggers it.
    assert_eq!(hook(&app, "GET", &url).await.0, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(app.get(&token, "/api/v1/today").await.1["habits"][0]["value"], 2);
}

#[tokio::test]
async fn webhook_on_a_boolean_checks_today() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;
    let url = webhook_url(&app, &token, &habit).await;

    for _ in 0..2 {
        let (status, body) = hook(&app, "POST", &url).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!((body["value"].clone(), body["done"].clone()), (json!(1), json!(true)));
    }
}

#[tokio::test]
async fn webhook_on_a_weekly_boolean_counts_one_day() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app
        .habit(&token, json!({ "name": "Gym", "kind": "boolean", "schedule": "weekly", "goal": 2 }))
        .await;
    let url = webhook_url(&app, &token, &habit).await;

    for _ in 0..2 {
        let (_, body) = hook(&app, "POST", &url).await;
        assert_eq!(
            (body["value"].clone(), body["period_value"].clone(), body["done"].clone()),
            (json!(1), json!(1), json!(false))
        );
    }
}

#[tokio::test]
async fn webhook_secrets_can_be_rotated_and_disabled() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;

    let (status, body) = hook(&app, "POST", &format!("{PUBLIC_URL}/hook/unknown")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error_code(&body), "not_found");

    let first = webhook_url(&app, &token, &habit).await;
    let second = webhook_url(&app, &token, &habit).await;
    assert_ne!(first, second);
    assert_eq!(hook(&app, "POST", &first).await.0, StatusCode::NOT_FOUND);
    assert_eq!(hook(&app, "POST", &second).await.0, StatusCode::OK);

    let (status, _) =
        app.api(&token, "DELETE", &format!("/api/v1/habits/{habit}/webhook"), Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(hook(&app, "POST", &second).await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        app.get(&token, &format!("/api/v1/habits/{habit}")).await.1["webhook_url"],
        Value::Null
    );
}

#[tokio::test]
async fn webhooks_are_rate_limited_per_secret() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let a = app.habit(&token, boolean("daily")).await;
    let b = app.habit(&token, boolean("daily")).await;
    let url_a = webhook_url(&app, &token, &a).await;
    let url_b = webhook_url(&app, &token, &b).await;

    for _ in 0..60 {
        assert_eq!(hook(&app, "POST", &url_a).await.0, StatusCode::OK);
    }
    let (status, body) = hook(&app, "POST", &url_a).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(error_code(&body), "rate_limited");
    assert_eq!(hook(&app, "POST", &url_b).await.0, StatusCode::OK);
}

#[tokio::test]
async fn app_pages_need_a_session() {
    let app = TestApp::new().await;
    let page = |cookie: Option<&str>| {
        let mut request = Request::get("/habits/new?x=1");
        if let Some(cookie) = cookie {
            request = request.header(header::COOKIE, format!("habitd_session={cookie}"));
        }
        request.body(Body::empty()).unwrap()
    };

    // An unauthenticated visit goes to the login, and comes back to the same page.
    for cookie in [None, Some("hbt_made-up")] {
        let response = app.send(page(cookie)).await;
        assert_eq!(response.status(), StatusCode::SEE_OTHER);
        assert_eq!(
            response.headers()[header::LOCATION],
            "/auth/login?redirect=%2Fhabits%2Fnew%3Fx%3D1"
        );
    }
    let session = app.session("alice").await;
    assert_ne!(app.send(page(Some(&session))).await.status(), StatusCode::SEE_OTHER);

    // The API's own prefixes never fall through to the app.
    for path in ["/auth/nope", "/api/nope", "/hook/a/b"] {
        let response = app.send(Request::get(path).body(Body::empty()).unwrap()).await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
    }
}

#[tokio::test]
async fn streaks_are_reported_by_today_and_by_writes() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let daily = app.habit(&token, boolean("daily")).await;
    let weekly = app
        .habit(&token, json!({ "name": "Gym", "kind": "boolean", "schedule": "weekly", "goal": 2 }))
        .await;

    app.set(&token, &daily, MON, 1).await;
    app.set(&token, &daily, TUE, 1).await;
    // A write answers with the streak as it now stands.
    let status = app.set(&token, &daily, WED, 1).await;
    assert_eq!(status["streak"], 3);
    assert_eq!(status["best_streak"], 3);

    app.set(&token, &weekly, MON, 1).await;
    let status = app.set(&token, &weekly, TUE, 1).await;
    assert_eq!(status["streak"], 1);

    let row = |body: &Value, id: &str| {
        body["habits"].as_array().unwrap().iter().find(|h| h["id"] == id).unwrap().clone()
    };
    // The next Monday is still open, so nothing is broken yet...
    let body = today(&app, &token, NEXT_MON).await;
    assert_eq!(row(&body, &daily)["streak"], 0);
    assert_eq!(row(&body, &daily)["best_streak"], 3);
    assert_eq!(row(&body, &weekly)["streak"], 1);
    // ...and looking back at Tuesday shows the streak as it was then.
    let body = today(&app, &token, TUE).await;
    assert_eq!(row(&body, &daily)["streak"], 2);

    // Unchecking takes the day back out.
    let status = app.set(&token, &daily, WED, 0).await;
    assert_eq!(status["streak"], 2);
}

#[tokio::test]
async fn skipped_days_and_notes() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let habit = app.habit(&token, boolean("daily")).await;
    let day = |date: &str| format!("/api/v1/habits/{habit}/entries/{date}");

    app.set(&token, &habit, MON, 1).await;
    // Tuesday is skipped, with a note; neither touches the value.
    let (status, body) =
        app.api(&token, "PUT", &day(TUE), json!({ "skipped": true, "note": "  ill  " })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!((body["value"].clone(), body["skipped"].clone()), (json!(0), json!(true)));
    assert_eq!(body["note"], "ill");
    let status = app.set(&token, &habit, WED, 1).await;
    // The skipped day does not break the streak, and does not count either.
    assert_eq!(status["streak"], 2);

    // Changing one field leaves the others alone.
    let (_, body) = app.api(&token, "PUT", &day(TUE), json!({ "note": "better" })).await;
    assert_eq!((body["skipped"].clone(), body["note"].clone()), (json!(true), json!("better")));
    let (_, body) = app.api(&token, "PUT", &day(TUE), json!({ "skipped": false })).await;
    assert_eq!(body["note"], "better");
    assert_eq!(app.set(&token, &habit, WED, 1).await["streak"], 1);

    let view = today(&app, &token, TUE).await;
    let row = &view["habits"][0];
    assert_eq!(row["note"], "better");
    assert_eq!(row["week_values"], json!([1, 0, 1, 0, 0, 0, 0]));
    assert_eq!(row["week_skipped"], json!(vec![false; 7]));

    let (_, entries) =
        app.get(&token, &format!("/api/v1/entries?from={MON}&to={WED}&habit_id={habit}")).await;
    assert_eq!(entries[1]["note"], "better");

    // An empty change and an overlong note are refused.
    let (status, _) = app.api(&token, "PUT", &day(TUE), json!({})).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _) = app.api(&token, "PUT", &day(TUE), json!({ "note": "x".repeat(501) })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn habit_extras_are_validated() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let (status, body) = app
        .api(
            &token,
            "POST",
            "/api/v1/habits",
            json!({
                "name": "Read", "kind": "counter", "schedule": "daily", "goal": 20,
                "unit": " pages ", "color": "red", "reminder_time": "21:30",
            }),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["unit"], "pages");
    assert_eq!(body["color"], "red");
    assert_eq!(body["reminder_time"], "21:30");
    assert_eq!(body["category_id"], Value::Null);
    let path = format!("/api/v1/habits/{}", body["id"].as_str().unwrap());

    for bad in [
        json!({ "color": "pink" }),
        json!({ "reminder_time": "25:00" }),
        json!({ "reminder_time": "9:5" }),
        json!({ "unit": "x".repeat(21) }),
        json!({ "category_id": Uuid::now_v7() }),
    ] {
        let (status, body) = app.api(&token, "PATCH", &path, bad.clone()).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{bad} -> {body}");
    }
    // A reminder is removed with null; leaving the field out keeps it.
    let (_, body) = app.api(&token, "PATCH", &path, json!({ "color": "teal" })).await;
    assert_eq!(body["reminder_time"], "21:30");
    let (_, body) = app.api(&token, "PATCH", &path, json!({ "reminder_time": null })).await;
    assert_eq!(body["reminder_time"], Value::Null);
    // New habits default to the plain ink and no unit.
    let plain = app.habit(&token, boolean("daily")).await;
    let (_, body) = app.get(&token, &format!("/api/v1/habits/{plain}")).await;
    assert_eq!((body["color"].clone(), body["unit"].clone()), (json!("ink"), json!("")));
}

#[tokio::test]
async fn categories() {
    let app = TestApp::new().await;
    let token = app.user("alice").await;
    let other = app.user("bob").await;
    let create = |name: &'static str| {
        let (app, token) = (&app, &token);
        async move {
            let (status, body) =
                app.api(token, "POST", "/api/v1/categories", json!({ "name": name })).await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
            body["id"].as_str().unwrap().to_string()
        }
    };
    let health = create("Health").await;
    let work = create("Work").await;

    let habit = app.habit(&token, boolean("daily")).await;
    let habit_path = format!("/api/v1/habits/{habit}");
    let (status, body) =
        app.api(&token, "PATCH", &habit_path, json!({ "category_id": health })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["category_id"], health);

    // Folding a category is remembered, and `/today` carries both.
    let (_, body) = app
        .api(&token, "PATCH", &format!("/api/v1/categories/{health}"), json!({ "collapsed": true }))
        .await;
    assert_eq!((body["name"].clone(), body["collapsed"].clone()), (json!("Health"), json!(true)));
    let view = today(&app, &token, MON).await;
    assert_eq!(view["categories"].as_array().unwrap().len(), 2);
    assert_eq!(view["categories"][0]["collapsed"], true);
    assert_eq!(view["habits"][0]["category_id"], health);

    let (status, _) =
        app.api(&token, "PUT", "/api/v1/categories/order", json!({ "ids": [work, health] })).await;
    assert_eq!(status, StatusCode::OK);
    let (_, list) = app.get(&token, "/api/v1/categories").await;
    assert_eq!(list[0]["name"], "Work");
    let (status, _) =
        app.api(&token, "PUT", "/api/v1/categories/order", json!({ "ids": [work] })).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);

    // Someone else's category does not exist for them, nor can they use it.
    let path = format!("/api/v1/categories/{health}");
    let (status, _) = app.api(&other, "PATCH", &path, json!({ "name": "Mine" })).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let theirs = app.habit(&other, boolean("daily")).await;
    let (status, _) = app
        .api(&other, "PATCH", &format!("/api/v1/habits/{theirs}"), json!({ "category_id": health }))
        .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);

    // Deleting a category keeps its habits, uncategorised.
    let (status, _) = app.api(&token, "DELETE", &path, json!(null)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, body) = app.get(&token, &habit_path).await;
    assert_eq!(body["category_id"], Value::Null);
}
