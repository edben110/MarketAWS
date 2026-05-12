const { LambdaClient, CreateFunctionCommand, GetFunctionCommand, DeleteFunctionCommand } = require("@aws-sdk/client-lambda");
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const client = new LambdaClient({ region: "us-east-1" });

async function deploy() {
    const endpoints = JSON.parse(fs.readFileSync('outputs/endpoints.json', 'utf8'));
    const network = JSON.parse(fs.readFileSync('outputs/network.json', 'utf8'));
    const data = JSON.parse(fs.readFileSync('outputs/data-messaging.json', 'utf8'));
    const lambdas = JSON.parse(fs.readFileSync('outputs/lambdas.json', 'utf8'));
    
    const functionName = 'marketaws-get-products-lambda';
    const roleArn = 'arn:aws:iam::469134084749:role/marketaws-lambda-exec-role';
    const layerArn = lambdas.mysqlLayerArn;
    
    // Create Zip
    const buildDir = path.join('.build', 'get-products-temp');
    if (!fs.existsSync(buildDir)) fs.mkdirSync(buildDir, { recursive: true });
    fs.copyFileSync('lambdas/get-products/index.js', path.join(buildDir, 'index.js'));
    
    const zipPath = path.join('.build', 'get-products.zip');
    if (fs.existsSync(zipPath)) fs.unlinkSync(zipPath);
    
    console.log('Zipping...');
    execSync(`powershell.exe Compress-Archive -Path ${buildDir}/* -DestinationPath ${zipPath}`);
    
    const zipBuffer = fs.readFileSync(zipPath);
    
    try {
        console.log('Deleting existing function if any...');
        await client.send(new DeleteFunctionCommand({ FunctionName: functionName }));
    } catch (e) {}

    console.log('Creating function...');
    const command = new CreateFunctionCommand({
        FunctionName: functionName,
        Runtime: "nodejs18.x",
        Role: roleArn,
        Handler: "index.handler",
        Code: { ZipFile: zipBuffer },
        Timeout: 30,
        Layers: [layerArn],
        VpcConfig: {
            SubnetIds: [network.subnets.privateA, network.subnets.privateB],
            SecurityGroupIds: [network.securityGroups.lambda]
        },
        Environment: {
            Variables: {
                DB_HOST: data.rds.endpoint,
                DB_NAME: data.rds.databaseName,
                DB_USER: "marketawsadmin",
                DB_PASSWORD: "12345678"
            }
        }
    });

    const result = await client.send(command);
    console.log('Function created:', result.FunctionArn);
}

deploy().catch(console.error);
