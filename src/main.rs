#![deny(warnings)]
extern crate pretty_env_logger;
use bytes::BufMut;
use futures::{TryFutureExt, TryStreamExt};
use rand::distributions::Alphanumeric;
use rand::{thread_rng, Rng};
use std::env;
use std::fs::File;
use std::io::prelude::*;
use std::path::PathBuf;
use std::process::Command;
use warp::{
    http::{Response, StatusCode},
    multipart, reject, Filter,
};

#[derive(Debug)]
struct DivideByZero;

impl reject::Reject for DivideByZero {}

#[tokio::main]
async fn main() {
    pretty_env_logger::init();

    // if "bitcoind" argument passed, the timestamp verification will be executed with bitcoin core, otherwise with
    // a public Esplora explorer
    let cli_arg = std::env::args().nth(1).unwrap_or("None".to_string());

    let mut path = PathBuf::new();

    match env::current_exe() {
        Ok(exe_path) => {
            path.push(exe_path.clone());
            println!("Path of this executable is: {}", exe_path.display())
        }
        Err(e) => {
            println!("failed to get current exe path: {}", e);
            return;
        }
    };

    path.pop();
    path.pop();
    path.pop();

    let path_public: PathBuf = [path.clone(), PathBuf::from("public")].iter().collect();

    let hello = warp::path("verify2").map(|| "ots file verified!"); // TODO

    let route_timestamp = warp::path("timestamp")
        .and(warp::body::content_length_limit(1024 * 5))
        .and(multipart::form())
        .and_then(|form: multipart::FormData| {
            async {
                // Collect the fields into (name, value): (String, Vec<u8>)
                let part: Result<Vec<(String, Vec<u8>)>, warp::Rejection> = form
                    .and_then(|part| {
                        let name = part.name().to_string();
                        let value = part.stream().try_fold(Vec::new(), |mut vec, data| {
                            vec.put(data);
                            async move { Ok(vec) }
                        });
                        value.map_ok(move |vec| (name, vec))
                    })
                    .try_collect()
                    .await
                    .map_err(|e| {
                        panic!("multipart error: {:?}", e);
                    });
                part
            }
        })
        .map(|p: Vec<(String, Vec<u8>)>| {
            println!("{:?}", p);

            let digest = &p[0].1;
            let digest_hex = std::str::from_utf8(&digest).unwrap();
            println!("digest: {:?}", digest_hex);

            // this is file timestamping
            let output = Command::new("ots-cli.js")
                .arg("stamp")
                .arg("-d")
                .arg(digest_hex)
                .output()
                .unwrap();

            let ret = if !output.status.success() {
                // TODO check the actual content for success?
                Response::builder()
                    .status(StatusCode::BAD_REQUEST)
                    .body(output.stdout.clone())
            } else {
                let s = String::from_utf8(output.stdout.clone()).unwrap();
                println!("{:?}", s);
                let mut data = Vec::new();
                let res = if !s.contains("already exists") {
                    let mut file = File::open(format!("{}.ots", digest_hex)).unwrap();
                    file.read_to_end(&mut data).unwrap();
                    std::fs::remove_file(format!("{}.ots", digest_hex)).unwrap();
                    Response::builder()
                        .header("Content-Type", "application/octet-stream")
                        .body(data)
                } else {
                    Response::builder()
                        .status(StatusCode::BAD_REQUEST)
                        .body(output.stdout)
                };
                res
            };
            ret
        });

    let route = warp::path("verify")
        .and(warp::body::content_length_limit(1024 * 5))
        .and(multipart::form())
        .and_then(|form: multipart::FormData| {
            async {
                // Collect the fields into (name, value): (String, Vec<u8>)
                let part: Result<Vec<(String, Vec<u8>)>, warp::Rejection> = form
                    .and_then(|part| {
                        let name = part.name().to_string();
                        let value = part.stream().try_fold(Vec::new(), |mut vec, data| {
                            vec.put(data);
                            async move { Ok(vec) }
                        });
                        value.map_ok(move |vec| (name, vec))
                    })
                    .try_collect()
                    .await
                    .map_err(|e| {
                        panic!("multipart error: {:?}", e);
                    });
                part
            }
        })
        .map(move |p: Vec<(String, Vec<u8>)>| {
            let digest = &p[0].1;
            let digest_hex = std::str::from_utf8(&digest).unwrap();
            println!("digest: {:?}", digest_hex);

            let ots_file = &p[1].1;
            println!("ots_file len: {:?}", ots_file.len());

            // TODO graceful errors
            let mut file = File::create(format!("/tmp/{}.ots", digest_hex)).unwrap();
            file.write_all(&ots_file).unwrap();

            let output = if cli_arg.clone() == "bitcoind" {
                println!("{:?}", "Verifying with Bitcon Core");
                Command::new("ots-cli.js")
                    .arg("verify")
                    .arg(format!("/tmp/{}.ots", digest_hex))
                    .arg("-d")
                    .arg(digest_hex)
                    .output()
                    .unwrap()
            } else {
                println!("{:?}", "Verifying with public Esplora");
                Command::new("ots-cli.js")
                    .arg("verify")
                    .arg("-i") // ignore bitcoind
                    .arg(format!("/tmp/{}.ots", digest_hex))
                    .arg("-d")
                    .arg(digest_hex)
                    .output()
                    .unwrap()
            };

            let str1: String = String::from_utf8(output.stdout.clone()).unwrap();
            println!("{:?}", str1);

            let ret = if !output.status.success() {
                // TODO check the actual content for success?
                Response::builder()
                    .status(StatusCode::BAD_REQUEST)
                    .body(output.stdout)
            } else {
                Response::builder().body(output.stdout)
            };
            ret
        });

    let route_upgrade = warp::path("upgrade")
        .and(warp::body::content_length_limit(1024 * 5))
        .and(multipart::form())
        .and_then(|form: multipart::FormData| {
            async {
                // Collect the fields into (name, value): (String, Vec<u8>)
                let part: Result<Vec<(String, Vec<u8>)>, warp::Rejection> = form
                    .and_then(|part| {
                        let name = part.name().to_string();
                        let value = part.stream().try_fold(Vec::new(), |mut vec, data| {
                            vec.put(data);
                            async move { Ok(vec) }
                        });
                        value.map_ok(move |vec| (name, vec))
                    })
                    .try_collect()
                    .await
                    .map_err(|e| {
                        panic!("multipart error: {:?}", e);
                    });
                part
            }
        })
        .map(move |p: Vec<(String, Vec<u8>)>| {
            let ots_file = &p[0].1;
            println!("ots_file len: {:?}", ots_file.len());

            // create random filename
            let filename: String = thread_rng().sample_iter(&Alphanumeric).take(24).collect();

            // TODO graceful errors
            let mut file = File::create(format!("/tmp/{}.ots", filename)).unwrap();
            file.write_all(&ots_file).unwrap();

            let output = Command::new("ots-cli.js")
                .arg("upgrade")
                .arg(format!("/tmp/{}.ots", filename))
                .output()
                .unwrap();

            let str1: String = String::from_utf8(output.stdout.clone()).unwrap();
            println!("{:?}", str1);

            let ret = if !output.status.success() {
                // TODO check the actual content for success?
                Response::builder()
                    .status(StatusCode::BAD_REQUEST)
                    .body(output.stdout)
            } else {
                let s = String::from_utf8(output.stdout.clone()).unwrap();
                println!("{:?}", s);
                let mut data = Vec::new();

                let mut file = File::open(format!("/tmp/{}.ots", filename)).unwrap();
                file.read_to_end(&mut data).unwrap();
                std::fs::remove_file(format!("/tmp/{}.ots", filename)).unwrap();
                std::fs::remove_file(format!("/tmp/{}.ots.bak", filename)).unwrap();
                Response::builder()
                    .header("Content-Type", "application/octet-stream")
                    .body(data)
            };
            ret
        });

    let routes = hello
        .or(warp::fs::dir(path_public))
        .or(route)
        .or(route_timestamp)
        .or(route_upgrade);

    warp::serve(routes).run(([127, 0, 0, 1], 7777)).await;
}
