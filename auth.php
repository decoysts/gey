<?php
session_start();
require "dbconnect.php";

if (isset($_SESSION['verified']) && $_SESSION['verified'] == '1') {
    // Пользователь уже авторизован
    echo "<center><h2>Authorization complete</h2></center>";
    echo "Hello " . $_SESSION['username'];
    echo "<br><br>";
    echo '<form action="logout.php">
            <button type="submit">Logout</button>
          </form>';
    echo '<br>';
    echo '<form action="students2.php">
            <button type="submit">Students</button>
          </form>';
} else {
    // Форма авторизации
    ?>
    <center><h2>Authorization</h2></center>
    <form action="" method="post">
        <br>
        <label>Login</label><br>
        <input type="text" name="auth_login" placeholder="Enter login" required><br><br>
        
        <label>Password</label><br>
        <input type="password" name="auth_pass" placeholder="Enter password" required><br><br>
        
        <button type="submit" name="auth">Enter</button>
    </form>
    <?php
}

// Обработка формы входа
if (isset($_POST['auth'])) {
    $login = $_POST['auth_login'];
    $pass  = $_POST['auth_pass'];

    $query = "SELECT id FROM auth WHERE login = '$login' AND password = '$pass'";
    $result = $conn->query($query);

    if ($result && $result->num_rows == 1) {
        $row = $result->fetch_assoc();
        $_SESSION['verified'] = '1';
        $_SESSION['username'] = $login;
        $_COOKIE['username'] = $login; // можно убрать, если не нужно

        header("Location: auth.php");
        exit();
    } else {
        echo "<center><h3 style='color:red;'>Неверный логин или пароль!</h3></center>";
    }
}
?>
